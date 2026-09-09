import Foundation
import Testing
@testable import ThrallFeature

/// Driven entirely by the captured 48-container response. The two spine tests
/// come first because they are the reason `ThrallStackID` is a triple: get
/// identity wrong and stacks silently merge or duplicate, which is the
/// highest-risk failure in the app.
@Suite("ThrallReconciler")
struct ThrallReconcilerTests {
    private static let engineKey = "unix:/Users/me/.orbstack/run/docker.sock"

    private func fixtureContainers() throws -> [ThrallContainerDTO] {
        try JSONDecoder().decode([ThrallContainerDTO].self,
                                 from: try Fixtures.data(Fixtures.containersAll48))
    }

    private func world(diskCandidates: [ThrallDiskCandidate] = [],
                       probe: ThrallFileProbe = .nothingExists) throws -> ThrallWorld {
        ThrallReconciler.reconcile(engineKey: Self.engineKey,
                                   containers: try fixtureContainers(),
                                   diskCandidates: diskCandidates,
                                   probe: probe,
                                   now: Date(timeIntervalSince1970: 1_789_000_000))
    }

    // MARK: - Spine

    /// **Spine 1: the `compose` name collision must SPLIT into two stacks.**
    /// Two unrelated trees — a `UlynkHomeCloud` deployment and a scratchpad
    /// copy of `UlynkControlPlane` — both produce the project name `compose`.
    /// Keyed on the name alone they become one row holding two projects.
    @Test("the compose name collision splits into two stacks")
    func nameCollisionSplits() throws {
        let composeStacks = try world().stacks.filter { $0.displayName == "compose" }
        #expect(composeStacks.count == 2)
        #expect(composeStacks.allSatisfy { $0.containerCount == 1 })
        // Different identities, same display name — exactly the situation the
        // triple exists for.
        #expect(Set(composeStacks.map(\.id)).count == 2)
        let directories = composeStacks.compactMap(\.id.workingDirectory).map(\.value)
        #expect(directories.contains { $0.contains("ulynkhomecloud") })
        #expect(directories.contains { $0.contains("ulynkcontrolplane") })
    }

    /// **Spine 2: `althaqeel`'s `/Run` and `/run` must MERGE into one stack.**
    /// They are the same directory on a case-insensitive filesystem. Keyed
    /// literally, one stack of 12 becomes two of unequal size and every action
    /// applies to half of it.
    @Test("the Run/run case difference merges into one stack")
    func caseOnlyDifferenceMerges() throws {
        let stacks = try world().stacks.filter { $0.displayName == "althaqeel" }
        #expect(stacks.count == 1)
        #expect(stacks[0].containerCount == 12)
        // The folded key merged them; the display keeps the engine's spelling.
        let display = try #require(stacks[0].workingDirectoryDisplay)
        #expect(display.hasSuffix("/Run") || display.hasSuffix("/run"))
    }

    // MARK: - Shape

    @Test("five stacks and the loose pseudo-stack, with the right counts")
    func stackCounts() throws {
        let stacks = try world().stacks
        #expect(stacks.map { "\($0.displayName)=\($0.containerCount)" } == [
            "aai1058=24", "althaqeel=12", "compose=1", "compose=1", "optimus=8",
            "Unmanaged=2",
        ])
    }

    /// Sorted by identity, never by state — with containers flapping, a
    /// state-keyed order turns the list into a slot machine.
    @Test("stacks sort by name then working directory, with loose containers last")
    func stackOrderingIsStable() throws {
        let stacks = try world().stacks
        #expect(stacks.last?.id.isLoose == true)
        let named = stacks.dropLast()
        #expect(named.map(\.displayName) == named.map(\.displayName).sorted())
        // The two `compose` stacks are ordered by their folded directory, so
        // the order does not depend on dictionary iteration.
        let composeKeys = stacks.filter { $0.displayName == "compose" }
            .compactMap(\.id.workingDirectory).map(\.value)
        #expect(composeKeys == composeKeys.sorted())
    }

    /// Recomputing from the same input must give the same answer — the
    /// property that lets the 10 s poll run without the list twitching.
    @Test("reconciling twice is identical")
    func deterministic() throws {
        let first = try world()
        let second = try world()
        #expect(first == second)
    }

    @Test("the two unlabelled containers get a real row, never hidden")
    func looseContainersAreVisible() throws {
        let loose = try #require(try world().stacks.first { $0.id.isLoose })
        #expect(loose.displayName == ThrallReconciler.looseStackName)
        #expect(loose.containerCount == 2)
        // No compose service label, so each container becomes its own service
        // row named after itself.
        #expect(loose.services.map(\.name).sorted() == ["ia565-pg", "ulynk-lan-pg"])
        #expect(!loose.isConfigMissing, "no compose files were ever declared, so none are missing")
    }

    @Test("services group by compose service and replicas order by number")
    func serviceGrouping() throws {
        let stack = try #require(try world().stacks.first { $0.displayName == "optimus" })
        #expect(!stack.services.isEmpty)
        #expect(stack.services.map(\.name) == stack.services.map(\.name).sorted())
        for service in stack.services {
            let numbers = service.containers.compactMap(\.replicaNumber)
            #expect(numbers == numbers.sorted())
        }
        #expect(stack.services.flatMap(\.containers).count == 24 - 16)
    }

    // MARK: - Config presence

    /// `aai1058` and both `compose` stacks declare files that are gone. This is
    /// the orphaned-stack state — 26 of the 48 containers here.
    @Test("stacks whose config files are gone are flagged config-missing")
    func configMissing() throws {
        let stacks = try world(probe: .filesystem).stacks
        let missing = stacks.filter(\.isConfigMissing)
        #expect(missing.map(\.displayName).sorted() == ["aai1058", "compose", "compose"])
        #expect(missing.allSatisfy { !$0.configFiles.isEmpty })
        #expect(missing.allSatisfy { $0.absentConfigFiles.count == $0.configFiles.count })
        // aai1058 declares two files and both are gone — the comma-split.
        let aai = try #require(stacks.first { $0.displayName == "aai1058" })
        #expect(aai.configFiles.count == 2)
    }

    /// Keyed on the **files**, never the working directory: `aai1058`'s
    /// working directory is still on disk while both its compose files are not.
    /// A directory check would report the largest broken stack as healthy.
    @Test("a present working directory does not clear config-missing")
    func directoryIsNotAProxyForTheConfig() throws {
        let stacks = try world(probe: .filesystem).stacks
        let aai = try #require(stacks.first { $0.displayName == "aai1058" })
        let directory = try #require(aai.workingDirectoryDisplay)
        #expect(FileManager.default.fileExists(atPath: directory),
                "the fixture's premise: the directory outlived the config")
        #expect(aai.isConfigMissing)
    }

    @Test("a stack whose files are all present is not config-missing")
    func configPresent() throws {
        let stacks = try world(probe: .everythingExists).stacks
        #expect(stacks.allSatisfy { !$0.isConfigMissing })
    }

    @Test("a partially-present config is not reported as missing")
    func partialConfigPresence() throws {
        let containers = try fixtureContainers()
        let aaiFiles = ThrallReconciler.configFiles(
            from: try #require(containers.first {
                $0.labels["com.docker.compose.project"] == "aai1058"
            }).labels)
        let firstOnly = aaiFiles[0]
        let probe = ThrallFileProbe { $0 == firstOnly }
        let stack = try #require(
            ThrallReconciler.reconcile(engineKey: Self.engineKey, containers: containers,
                                       probe: probe)
                .stacks.first { $0.displayName == "aai1058" })
        #expect(!stack.isConfigMissing)
        #expect(stack.absentConfigFiles.count == 1)
    }

    // MARK: - Disk as the source of what is declared

    /// A fully-down stack has no containers at all, so it exists only because
    /// disk says so. Without this it would not appear and could never be
    /// brought up.
    @Test("a stack with zero containers is listed from disk alone")
    func zeroContainerStackFromDisk() throws {
        let candidate = ThrallDiskCandidate(projectName: "dormant",
                                            workingDirectory: "/Users/me/Projects/Dormant",
                                            configFiles: ["/Users/me/Projects/Dormant/compose.yml"],
                                            declaredServices: ["api", "db"])
        let stack = try #require(try world(diskCandidates: [candidate],
                                           probe: .everythingExists)
            .stacks.first { $0.displayName == "dormant" })
        #expect(stack.containerCount == 0)
        #expect(stack.health == .down)
        #expect(stack.services.map(\.name) == ["api", "db"])
        #expect(stack.services.allSatisfy { $0.isDeclaredButAbsent })
        #expect(!stack.isConfigMissing)
    }

    @Test("a declared service with no container joins a running stack as absent")
    func declaredButAbsentServiceInRunningStack() throws {
        let containers = try fixtureContainers()
        let optimus = try #require(containers.first {
            $0.labels["com.docker.compose.project"] == "optimus"
        })
        let directory = try #require(
            optimus.labels["com.docker.compose.project.working_dir"])
        let running = Set(containers
            .filter { $0.labels["com.docker.compose.project"] == "optimus" }
            .compactMap { $0.labels["com.docker.compose.service"] })

        let candidate = ThrallDiskCandidate(
            projectName: "optimus",
            workingDirectory: directory,
            configFiles: ThrallReconciler.configFiles(from: optimus.labels),
            declaredServices: Array(running) + ["never-started"])
        let stack = try #require(
            ThrallReconciler.reconcile(engineKey: Self.engineKey, containers: containers,
                                       diskCandidates: [candidate], probe: .everythingExists)
                .stacks.first { $0.displayName == "optimus" })

        let absent = stack.services.filter(\.isDeclaredButAbsent)
        #expect(absent.map(\.name) == ["never-started"])
        #expect(stack.services.count == running.count + 1)
    }

    /// The disk candidate is matched on the same folded key, so the `/Run`
    /// spelling on disk still finds the `/run` containers.
    @Test("a disk candidate matches a running stack through the folded key")
    func diskCandidateMergesByFoldedKey() throws {
        let containers = try fixtureContainers()
        let directory = try #require(containers
            .first { $0.labels["com.docker.compose.project"] == "althaqeel" }?
            .labels["com.docker.compose.project.working_dir"])
        // Same directory, opposite case, and a trailing slash for good measure.
        let flipped = directory.hasSuffix("/Run")
            ? directory.replacingOccurrences(of: "/Run", with: "/run") + "/"
            : directory.replacingOccurrences(of: "/run", with: "/Run") + "/"
        let candidate = ThrallDiskCandidate(projectName: "althaqeel",
                                            workingDirectory: flipped,
                                            configFiles: [],
                                            declaredServices: ["ghost"])
        let stacks = ThrallReconciler.reconcile(engineKey: Self.engineKey,
                                                containers: containers,
                                                diskCandidates: [candidate],
                                                probe: .everythingExists)
            .stacks.filter { $0.displayName == "althaqeel" }
        #expect(stacks.count == 1, "the candidate must not create a second althaqeel")
        #expect(stacks[0].containerCount == 12)
        #expect(stacks[0].services.contains { $0.name == "ghost" && $0.isDeclaredButAbsent })
    }

    /// A real feature Docker Desktop lacks: the config changed after the
    /// containers were created, so what is running is not what is declared.
    @Test("a config newer than its containers marks the stack stale")
    func staleRelativeToConfig() throws {
        let containers = try fixtureContainers()
        let optimus = containers.filter { $0.labels["com.docker.compose.project"] == "optimus" }
        let directory = try #require(
            optimus.first?.labels["com.docker.compose.project.working_dir"])
        let newest = try #require(optimus.map(\.created).max())

        func stack(configModified: Date) throws -> ThrallStack {
            let candidate = ThrallDiskCandidate(projectName: "optimus",
                                                workingDirectory: directory,
                                                configFiles: [],
                                                configModified: configModified)
            return try #require(
                ThrallReconciler.reconcile(engineKey: Self.engineKey, containers: containers,
                                           diskCandidates: [candidate], probe: .everythingExists)
                    .stacks.first { $0.displayName == "optimus" })
        }
        let after = Date(timeIntervalSince1970: TimeInterval(newest) + 60)
        let before = Date(timeIntervalSince1970: TimeInterval(newest) - 60)
        let staleStack = try stack(configModified: after)
        let freshStack = try stack(configModified: before)
        #expect(staleStack.isStaleRelativeToConfig)
        #expect(!freshStack.isStaleRelativeToConfig)
    }

    @Test("with no config mtime known, nothing is claimed to be stale")
    func staleUnknownWithoutMtime() throws {
        let stacks = try world().stacks
        #expect(stacks.allSatisfy { !$0.isStaleRelativeToConfig })
    }

    // MARK: - Roll-up

    /// The machine as captured, per stack:
    ///
    /// | stack | running | exited | created | health |
    /// |---|---|---|---|---|
    /// | optimus | 8 | 0 | 0 | allRunning |
    /// | althaqeel | 11 | 1 | 0 | partiallyRunning |
    /// | aai1058 | 0 | 24 | 0 | stopped |
    /// | compose (x2) | 0 | 1 each | 0 | stopped |
    /// | Unmanaged | 0 | 1 | 1 | stopped |
    @Test("health rolls up from the state breakdown")
    func healthRollUp() throws {
        let stacks = try world().stacks
        let byName = Dictionary(grouping: stacks, by: \.displayName)

        let optimus = try #require(byName["optimus"]?.first)
        #expect(optimus.breakdown.running == 8)
        #expect(optimus.health == .allRunning)

        // The only mixed stack at capture time, and the one that proves
        // partiallyRunning is reachable.
        let althaqeel = try #require(byName["althaqeel"]?.first)
        #expect(althaqeel.breakdown.running == 11)
        #expect(althaqeel.breakdown.exited == 1)
        #expect(althaqeel.health == .partiallyRunning)

        let aai = try #require(byName["aai1058"]?.first)
        #expect(aai.breakdown.exited == 24)
        #expect(aai.health == .stopped)

        // Nothing here is `restarting` or `dead` — the 15 crash loops seen
        // while planning had all given up by capture, so `.unhealthy` is
        // exercised synthetically rather than from the fixture.
        #expect(stacks.allSatisfy { $0.health != .unhealthy })
    }

    @Test("a restarting or dead container makes the whole stack unhealthy",
          arguments: ["restarting", "dead"])
    func unhealthyRollUp(state: String) throws {
        var containers = try fixtureContainers()
            .filter { $0.labels["com.docker.compose.project"] == "optimus" }
        // Rewrite one container's state through the DTO's own decoder, so the
        // synthetic case still goes through the real wire path.
        let victim = try #require(containers.first)
        let json = """
            {"Id":"\(victim.id)","Names":["/optimus-synthetic-1"],"Image":"x","State":"\(state)",
             "Status":"Restarting (1) 2 seconds ago","Created":\(victim.created),
             "Labels":\(try labelsJSON(victim.labels))}
            """
        containers[0] = try JSONDecoder().decode(ThrallContainerDTO.self, from: Data(json.utf8))
        let stack = try #require(
            ThrallReconciler.reconcile(engineKey: Self.engineKey, containers: containers)
                .stacks.first { $0.displayName == "optimus" })
        #expect(stack.health == .unhealthy)
    }

    private func labelsJSON(_ labels: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("the whole machine's states add up to 48")
    func breakdownTotals() throws {
        let stacks = try world().stacks
        #expect(stacks.reduce(0) { $0 + $1.containerCount } == 48)
        #expect(stacks.reduce(0) { $0 + $1.breakdown.running } == 19)
        #expect(stacks.reduce(0) { $0 + $1.breakdown.exited } == 28)
        #expect(stacks.reduce(0) { $0 + $1.breakdown.created } == 1)
    }

    /// Comes free from the labels, with no compose file needed — which is what
    /// lets triage explain an orphaned stack.
    @Test("depends_on is read from labels, including for a config-missing stack")
    func dependenciesFromLabels() throws {
        let stacks = try world(probe: .filesystem).stacks
        let withDependencies = stacks.flatMap(\.services).filter { !$0.dependsOn.isEmpty }
        #expect(!withDependencies.isEmpty)
        let aai = try #require(stacks.first { $0.displayName == "aai1058" })
        #expect(aai.isConfigMissing)
        #expect(aai.services.contains { !$0.dependsOn.isEmpty },
                "the dependency graph must survive the compose file being gone")
    }

    @Test("an empty engine gives an empty world, not a crash")
    func emptyEngine() {
        let world = ThrallReconciler.reconcile(engineKey: Self.engineKey, containers: [])
        #expect(world.stacks.isEmpty)
        #expect(world.stack(.loose(engineKey: Self.engineKey)) == nil)
    }
}

@Suite("ThrallPathKey")
struct ThrallPathKeyTests {
    @Test("case-only differences fold together")
    func foldsCase() {
        #expect(ThrallPathKey("/Users/me/Projects/Althaqeel/Run")
            == ThrallPathKey("/Users/me/Projects/althaqeel/run"))
    }

    @Test("a trailing slash is not an identity")
    func stripsTrailingSlash() {
        #expect(ThrallPathKey("/tmp/project/") == ThrallPathKey("/tmp/project"))
        #expect(ThrallPathKey("/") == ThrallPathKey("/"))
    }

    @Test("dot components are resolved")
    func standardizes() {
        #expect(ThrallPathKey("/tmp/a/../project") == ThrallPathKey("/tmp/project"))
        #expect(ThrallPathKey("/tmp/./project") == ThrallPathKey("/tmp/project"))
    }

    @Test("a tilde expands to the same key as the absolute path")
    func expandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ThrallPathKey("~/Projects/App") == ThrallPathKey("\(home)/Projects/App"))
    }

    @Test("genuinely different directories stay different")
    func keepsRealDifferences() {
        #expect(ThrallPathKey("/Users/me/Projects/UlynkHomeCloud/deploy/compose")
            != ThrallPathKey("/tmp/scratch/UlynkControlPlane/deploy/compose"))
    }

    @Test("decomposed and precomposed Unicode fold together")
    func normalizesUnicode() {
        // "café" with a combining acute versus a precomposed é — APFS can
        // report either.
        #expect(ThrallPathKey("/tmp/cafe\u{0301}") == ThrallPathKey("/tmp/caf\u{00E9}"))
    }
}

@Suite("ThrallDependency")
struct ThrallDependencyTests {
    @Test("parses the label compose actually writes")
    func parsesRealLabel() {
        let parsed = ThrallDependency.parse(
            label: "redis:service_started:false,mysql:service_healthy:true")
        #expect(parsed.count == 2)
        #expect(parsed[0] == ThrallDependency(service: "redis", condition: "service_started",
                                              restartsDependents: false))
        #expect(parsed[1].restartsDependents)
    }

    /// A bad label must never cost the user a row.
    @Test("malformed clauses are dropped, not thrown",
          arguments: ["", "redis", "redis:only-two", ":empty:false", "a:b:c:d"])
    func dropsMalformed(label: String) {
        #expect(ThrallDependency.parse(label: label).isEmpty)
    }

    @Test("a good clause survives beside a bad one")
    func mixedLabel() {
        #expect(ThrallDependency.parse(label: "broken,db:service_healthy:false").count == 1)
    }
}
