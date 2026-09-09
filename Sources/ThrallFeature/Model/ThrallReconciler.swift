import Foundation

/// A compose project found on disk: what is *declared*, as opposed to what is
/// running.
///
/// Produced by the indexer (label seeding, then a pruned walk, then
/// `compose config`). The reconciler only consumes it, which is what keeps the
/// reconciler a pure function over a fixture.
public struct ThrallDiskCandidate: Hashable, Sendable {
    public let projectName: String
    public let workingDirectory: String
    public let configFiles: [String]
    /// Service names from `compose config`. Empty when the project was seeded
    /// from labels alone and its config has not been read.
    public let declaredServices: [String]
    /// Newest mtime across `configFiles`.
    public let configModified: Date?

    public init(projectName: String, workingDirectory: String, configFiles: [String],
                declaredServices: [String] = [], configModified: Date? = nil) {
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.configFiles = configFiles
        self.declaredServices = declaredServices
        self.configModified = configModified
    }
}

/// Whether a path is on disk, injected so the reconciler takes no I/O of its
/// own and a test can state the filesystem instead of arranging one.
public struct ThrallFileProbe: Sendable {
    public let exists: @Sendable (String) -> Bool

    public init(exists: @escaping @Sendable (String) -> Bool) {
        self.exists = exists
    }

    public static let filesystem = ThrallFileProbe {
        FileManager.default.fileExists(atPath: $0)
    }
    /// Everything is gone — the orphaned-stack world.
    public static let nothingExists = ThrallFileProbe { _ in false }
    /// Everything is present.
    public static let everythingExists = ThrallFileProbe { _ in true }
}

/// Turns engine and disk facts into the world.
///
/// A pure `nonisolated` function, so the whole of Thrall's interpretation of a
/// machine is reachable from a test with a JSON file and no daemon.
///
/// **Precedence, stated once here so no call site re-decides it:**
///
///  1. **Engine labels are authoritative for what exists and what state it is
///     in.** Nothing else may invent or remove a container.
///  2. **Disk is authoritative for what is declared.** A service in the config
///     with no container is `declaredButAbsent`, which is how a fully-down
///     stack gets rows instead of vanishing.
///  3. **Events are authoritative for nothing.** An event is an *invalidation
///     plus a history append*, never a delta applied to state — which is why
///     no event type appears in this file's signature. One dropped event would
///     otherwise leave the UI permanently wrong, and the daemon keeps only
///     minutes of history, so there is no replay to recover from.
public enum ThrallReconciler {
    /// The row title for containers belonging to no compose project.
    public static let looseStackName = "Unmanaged"

    public static func reconcile(engineKey: String,
                                 containers: [ThrallContainerDTO],
                                 diskCandidates: [ThrallDiskCandidate] = [],
                                 probe: ThrallFileProbe = .filesystem,
                                 now: Date = Date()) -> ThrallWorld {
        var grouped: [ThrallStackID: [ThrallContainerDTO]] = [:]
        var order: [ThrallStackID] = []
        for container in containers {
            let id = stackID(engineKey: engineKey, labels: container.labels)
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(container)
        }

        // Disk candidates keyed the same way, so a stack that is both running
        // and declared merges on exact ID equality and never fuzzily.
        var candidates: [ThrallStackID: ThrallDiskCandidate] = [:]
        for candidate in diskCandidates {
            let id = ThrallStackID(engineKey: engineKey,
                                   projectName: candidate.projectName,
                                   workingDirectory: ThrallPathKey(candidate.workingDirectory))
            // First wins: the indexer's own ordering decides, not dictionary
            // iteration order.
            if candidates[id] == nil { candidates[id] = candidate }
            if grouped[id] == nil {
                grouped[id] = []
                order.append(id)
            }
        }

        var stacks = order.map { id in
            makeStack(id: id,
                      containers: grouped[id] ?? [],
                      candidate: candidates[id],
                      probe: probe)
        }
        // **Sorted by identity, never by state.** With containers flapping,
        // any state-keyed order turns the list into a slot machine — this is
        // the single most consequential ordering decision in the app. The
        // loose pseudo-stack sorts last because it is an escape hatch, not a
        // headline.
        stacks.sort { left, right in
            if left.id.isLoose != right.id.isLoose { return right.id.isLoose }
            if left.displayName != right.displayName { return left.displayName < right.displayName }
            return (left.id.workingDirectory?.value ?? "") < (right.id.workingDirectory?.value ?? "")
        }
        return ThrallWorld(engineKey: engineKey, stacks: stacks, generatedAt: now)
    }

    /// Builds the identity from labels alone. Where the whole "project name is
    /// not an identity" rule lives.
    static func stackID(engineKey: String, labels: [String: String]) -> ThrallStackID {
        guard let project = labels["com.docker.compose.project"], !project.isEmpty else {
            return .loose(engineKey: engineKey)
        }
        let workingDirectory = labels["com.docker.compose.project.working_dir"]
            .flatMap { $0.isEmpty ? nil : ThrallPathKey($0) }
        return ThrallStackID(engineKey: engineKey,
                             projectName: project,
                             workingDirectory: workingDirectory)
    }

    /// Splits `com.docker.compose.project.config_files`.
    ///
    /// **The label is a comma-separated LIST.** 24 of the 48 containers here
    /// declare two files (`docker-compose.yml,docker-compose.dev.yml`), and
    /// treating the value as one path yields a filename that cannot exist —
    /// which would report every one of those containers' stack as
    /// config-missing whether it was or not.
    static func configFiles(from labels: [String: String]) -> [String] {
        (labels["com.docker.compose.project.config_files"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - One stack

    private static func makeStack(id: ThrallStackID,
                                  containers: [ThrallContainerDTO],
                                  candidate: ThrallDiskCandidate?,
                                  probe: ThrallFileProbe) -> ThrallStack {
        // Config files: the engine's labels first (they describe what actually
        // started), then anything the indexer adopted. Order-preserving union,
        // because the first file is the one compose treats as the base.
        var files: [String] = []
        for container in containers {
            for file in configFiles(from: container.labels) where !files.contains(file) {
                files.append(file)
            }
        }
        for file in candidate?.configFiles ?? [] where !files.contains(file) {
            files.append(file)
        }
        let absent = files.filter { !probe.exists($0) }

        var byService: [String: [ThrallContainerDTO]] = [:]
        var serviceOrder: [String] = []
        for container in containers {
            let service = container.labels["com.docker.compose.service"]
                ?? container.displayName
            if byService[service] == nil { serviceOrder.append(service) }
            byService[service, default: []].append(container)
        }

        var services: [ThrallService] = serviceOrder.map { name in
            let members = byService[name] ?? []
            return ThrallService(
                name: name,
                containers: members.map(makeContainer).sorted(by: containerOrder),
                // Read from any member: compose writes the same value on every
                // container of a service.
                dependsOn: ThrallDependency.parse(
                    label: members.first?.labels["com.docker.compose.depends_on"]),
                isDeclaredButAbsent: false)
        }
        // Rule 2: disk is authoritative for what is *declared*. Without this a
        // stack that is fully down would render as an empty row with no way to
        // see what it consists of.
        for declared in candidate?.declaredServices ?? [] where byService[declared] == nil {
            services.append(ThrallService(name: declared, containers: [],
                                          dependsOn: [], isDeclaredButAbsent: true))
        }
        services.sort { $0.name < $1.name }

        var breakdown = ThrallStateBreakdown()
        for container in containers { breakdown.add(ThrallContainerState(engineState: container.state)) }

        let newestContainer = containers.map(\.created).max()
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let isStale: Bool
        if let modified = candidate?.configModified, let newestContainer {
            isStale = modified > newestContainer
        } else {
            isStale = false
        }

        return ThrallStack(
            id: id,
            displayName: id.projectName ?? looseStackName,
            // The engine's own spelling, not the folded key.
            workingDirectoryDisplay: containers.first?
                .labels["com.docker.compose.project.working_dir"]
                ?? candidate?.workingDirectory,
            configFiles: files,
            absentConfigFiles: absent,
            services: services,
            breakdown: breakdown,
            health: health(breakdown: breakdown, hasDeclaredServices: !services.isEmpty),
            isStaleRelativeToConfig: isStale)
    }

    private static func makeContainer(_ dto: ThrallContainerDTO) -> ThrallContainer {
        ThrallContainer(
            id: dto.id,
            name: dto.displayName,
            image: dto.image,
            state: ThrallContainerState(engineState: dto.state),
            statusText: dto.status,
            created: Date(timeIntervalSince1970: TimeInterval(dto.created)),
            replicaNumber: dto.labels["com.docker.compose.container-number"].flatMap(Int.init),
            // Compose spells this `True`/`False`, not `true`/`false`.
            isOneOff: (dto.labels["com.docker.compose.oneoff"] ?? "").lowercased() == "true")
    }

    /// Replica number, then name. **Never state**, so a container changing
    /// state cannot make a row jump.
    private static func containerOrder(_ left: ThrallContainer, _ right: ThrallContainer) -> Bool {
        switch (left.replicaNumber, right.replicaNumber) {
        case (let l?, let r?) where l != r: return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        default: return left.name < right.name
        }
    }

    private static func health(breakdown: ThrallStateBreakdown,
                               hasDeclaredServices: Bool) -> ThrallStackHealth {
        guard breakdown.total > 0 else { return hasDeclaredServices ? .down : .stopped }
        if breakdown.dead > 0 || breakdown.restarting > 0 { return .unhealthy }
        if breakdown.running == breakdown.total { return .allRunning }
        if breakdown.running == 0 { return .stopped }
        return .partiallyRunning
    }
}
