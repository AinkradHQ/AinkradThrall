import Foundation

/// What a container is doing, as a closed set.
///
/// `unknown` carries the raw string rather than collapsing to a default: a
/// state Thrall does not recognise must still render as itself, because
/// showing `dead` as `exited` would hide the one state that needs manual
/// intervention.
public enum ThrallContainerState: Hashable, Sendable {
    case created
    case running
    case restarting
    case paused
    case exited
    case dead
    case removing
    case unknown(String)

    public init(engineState raw: String) {
        switch raw.lowercased() {
        case "created": self = .created
        case "running": self = .running
        case "restarting": self = .restarting
        case "paused": self = .paused
        case "exited": self = .exited
        case "dead": self = .dead
        case "removing": self = .removing
        default: self = .unknown(raw)
        }
    }

    public var isLive: Bool {
        switch self {
        case .running, .restarting, .paused: return true
        default: return false
        }
    }

    /// Ordering for the worst-state roll-up. Higher wins.
    public var severity: Int {
        switch self {
        case .dead: return 5
        case .restarting: return 4
        case .exited: return 3
        case .paused: return 2
        case .removing: return 1
        case .created: return 1
        case .running: return 0
        case .unknown: return 3
        }
    }

    public var label: String {
        switch self {
        case .created: return "Created"
        case .running: return "Running"
        case .restarting: return "Restarting"
        case .paused: return "Paused"
        case .exited: return "Exited"
        case .dead: return "Dead"
        case .removing: return "Removing"
        case .unknown(let raw): return raw.capitalized
        }
    }
}

/// One `depends_on` clause, read straight off the container's labels.
///
/// The dependency graph therefore needs **no compose file** — which is what
/// lets triage say "`api` depends_on `db`; `db` is exited (1)" for a stack
/// whose compose file is gone. Wire shape:
/// `redis:service_started:false,mysql:service_healthy:false`.
public struct ThrallDependency: Hashable, Sendable {
    public let service: String
    /// `service_started`, `service_healthy`, `service_completed_successfully`.
    public let condition: String
    /// The third field: compose's `restart` flag for the dependency.
    public let restartsDependents: Bool

    public init(service: String, condition: String, restartsDependents: Bool) {
        self.service = service
        self.condition = condition
        self.restartsDependents = restartsDependents
    }

    /// Parses the whole label. Malformed clauses are dropped rather than
    /// failing the stack: a bad label must never cost the user a row.
    public static func parse(label: String?) -> [ThrallDependency] {
        guard let label, !label.isEmpty else { return [] }
        return label.split(separator: ",").compactMap { clause in
            let parts = clause.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty else { return nil }
            return ThrallDependency(service: String(parts[0]),
                                    condition: String(parts[1]),
                                    restartsDependents: parts[2] == "true")
        }
    }
}

public struct ThrallContainer: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let image: String
    public let state: ThrallContainerState
    /// The engine's prose, e.g. `Exited (137) 3 hours ago`. Display only.
    public let statusText: String
    public let created: Date
    /// `com.docker.compose.container-number`, which is what orders replicas.
    public let replicaNumber: Int?
    public let isOneOff: Bool

    public init(id: String, name: String, image: String, state: ThrallContainerState,
                statusText: String, created: Date, replicaNumber: Int?, isOneOff: Bool) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.statusText = statusText
        self.created = created
        self.replicaNumber = replicaNumber
        self.isOneOff = isOneOff
    }
}

public struct ThrallService: Hashable, Sendable, Identifiable {
    public let name: String
    public let containers: [ThrallContainer]
    public let dependsOn: [ThrallDependency]
    /// Declared in the compose config with no container to show for it. **This
    /// is how a fully-down stack gets rows** rather than appearing empty.
    public let isDeclaredButAbsent: Bool

    public var id: String { name }

    /// Worst state among its containers, or nil when there are none.
    public var worstState: ThrallContainerState? {
        containers.max { $0.state.severity < $1.state.severity }?.state
    }

    public init(name: String, containers: [ThrallContainer],
                dependsOn: [ThrallDependency], isDeclaredButAbsent: Bool) {
        self.name = name
        self.containers = containers
        self.dependsOn = dependsOn
        self.isDeclaredButAbsent = isDeclaredButAbsent
    }
}

/// Per-state counts for the stack row's ribbon. A struct rather than a
/// dictionary so the ribbon cannot be handed a state it has no colour for.
public struct ThrallStateBreakdown: Hashable, Sendable {
    public var running = 0
    public var restarting = 0
    public var exited = 0
    public var paused = 0
    public var created = 0
    public var dead = 0
    public var other = 0

    public var total: Int { running + restarting + exited + paused + created + dead + other }

    public mutating func add(_ state: ThrallContainerState) {
        switch state {
        case .running: running += 1
        case .restarting: restarting += 1
        case .exited: exited += 1
        case .paused: paused += 1
        case .created: created += 1
        case .dead: dead += 1
        case .removing, .unknown: other += 1
        }
    }
}

/// How a stack row reads at a glance.
public enum ThrallStackHealth: Int, Hashable, Sendable, Comparable {
    /// Declared on disk with nothing running.
    case down = 0
    case allRunning = 1
    case partiallyRunning = 2
    case stopped = 3
    /// Something is `restarting` or `dead`. Crash-*loop* detection is M2; this
    /// is only the state roll-up.
    case unhealthy = 4

    public static func < (lhs: ThrallStackHealth, rhs: ThrallStackHealth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ThrallStack: Hashable, Sendable, Identifiable {
    public let id: ThrallStackID
    /// The project name, or a fixed label for the loose pseudo-stack.
    public let displayName: String
    /// The working directory **as the engine spelled it** — not the folded
    /// key. `althaqeel` reports both `/Run` and `/run`; the key merges them and
    /// this shows the one the user will recognise.
    public let workingDirectoryDisplay: String?
    /// Adopted config files, comma-split from the label.
    public let configFiles: [String]
    /// The subset of `configFiles` that is not on disk.
    public let absentConfigFiles: [String]
    public let services: [ThrallService]
    public let breakdown: ThrallStateBreakdown
    public let health: ThrallStackHealth
    /// A config file changed after its containers were created, so what is
    /// running is not what is declared. Docker Desktop has no equivalent.
    public let isStaleRelativeToConfig: Bool

    /// **Every declared config file is gone from disk.**
    ///
    /// A first-class state, not an error: it is `aai1058`, the largest stack on
    /// this machine (24 containers). `docker compose down` needs the file it
    /// was started from, so such a stack is unreachable by normal tooling and
    /// can only be torn down by label. It offers engine-level actions only —
    /// never "Up", which has nothing to read.
    ///
    /// Keyed on the **files**, never on the working directory: `aai1058`'s
    /// working directory still exists while both of its compose files do not,
    /// so a directory check would report it healthy.
    public var isConfigMissing: Bool {
        !configFiles.isEmpty && absentConfigFiles.count == configFiles.count
    }

    public var containerCount: Int { breakdown.total }

    public init(id: ThrallStackID, displayName: String, workingDirectoryDisplay: String?,
                configFiles: [String], absentConfigFiles: [String], services: [ThrallService],
                breakdown: ThrallStateBreakdown, health: ThrallStackHealth,
                isStaleRelativeToConfig: Bool) {
        self.id = id
        self.displayName = displayName
        self.workingDirectoryDisplay = workingDirectoryDisplay
        self.configFiles = configFiles
        self.absentConfigFiles = absentConfigFiles
        self.services = services
        self.breakdown = breakdown
        self.health = health
        self.isStaleRelativeToConfig = isStaleRelativeToConfig
    }
}

/// Everything Thrall believes about one engine at one instant.
public struct ThrallWorld: Hashable, Sendable {
    public let engineKey: String
    public let stacks: [ThrallStack]
    public let generatedAt: Date

    public init(engineKey: String, stacks: [ThrallStack], generatedAt: Date) {
        self.engineKey = engineKey
        self.stacks = stacks
        self.generatedAt = generatedAt
    }

    public static func empty(engineKey: String, at date: Date = Date()) -> ThrallWorld {
        ThrallWorld(engineKey: engineKey, stacks: [], generatedAt: date)
    }

    public func stack(_ id: ThrallStackID) -> ThrallStack? {
        stacks.first { $0.id == id }
    }
}
