import Foundation

/// A container as `GET /containers/json` describes it.
///
/// A wire DTO, not the domain model — `ThrallStack` and friends are Task D's,
/// and keeping them apart is what lets the reconciler stay a pure function
/// over a fixture. Only the fields Thrall reads are declared; the engine sends
/// more (`Mounts`, `NetworkSettings`, `ImageManifestDescriptor`) and decoding
/// what nothing uses is just a bigger surface to break.
public struct ThrallContainerDTO: Decodable, Equatable, Sendable {
    public let id: String
    /// As sent, each with a leading `/`.
    public let names: [String]
    public let image: String
    public let imageID: String
    public let command: String
    /// Unix seconds. Note the inconsistency: this endpoint sends an integer
    /// while `inspect` sends an RFC 3339 string for the same concept.
    public let created: Int
    /// `running`, `exited`, `created`, `restarting`, `paused`, `dead`.
    public let state: String
    /// Prose, e.g. `Exited (137) 3 hours ago`. Display only — parsing it for
    /// an exit code is a localisation bug waiting to happen, and `inspect`
    /// gives the number.
    public let status: String
    public let labels: [String: String]
    public let ports: [Port]

    public struct Port: Decodable, Equatable, Sendable {
        public let ip: String?
        public let privatePort: Int
        public let publicPort: Int?
        public let type: String

        enum CodingKeys: String, CodingKey {
            case ip = "IP"
            case privatePort = "PrivatePort"
            case publicPort = "PublicPort"
            case type = "Type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case imageID = "ImageID"
        case command = "Command"
        case created = "Created"
        case state = "State"
        case status = "Status"
        case labels = "Labels"
        case ports = "Ports"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        names = try container.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
        imageID = try container.decodeIfPresent(String.self, forKey: .imageID) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        created = try container.decodeIfPresent(Int.self, forKey: .created) ?? 0
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        // Both of these are documented as nullable and arrive as `{}`/`[]` on
        // this daemon. Defaulted rather than optional so no call site has to
        // tell "no labels" from "labels absent" — there is no difference.
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        ports = try container.decodeIfPresent([Port].self, forKey: .ports) ?? []
    }

    /// The name without its leading slash. The engine sends `/optimus-scheduler-1`.
    public var displayName: String {
        guard let first = names.first else { return String(id.prefix(12)) }
        return first.hasPrefix("/") ? String(first.dropFirst()) : first
    }
}

/// The subset of `GET /containers/{id}/json` Thrall reads.
///
/// `restartCount` is the reason this endpoint is called at all: it does not
/// appear in the list response, and crash-loop detection cannot be done
/// without it. It is **lifetime-cumulative**, so it needs a recency clause
/// before it means anything — see the M2 plan.
public struct ThrallContainerInspectDTO: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let created: Date?
    public let restartCount: Int
    public let state: State
    public let restartPolicy: RestartPolicy
    /// `Config.Tty`. **Not** used to pick log framing — that comes from the
    /// response's own `Content-Type`, because this value can go stale between
    /// the inspect and the log call if the container is recreated.
    public let hasTTY: Bool

    public struct State: Decodable, Equatable, Sendable {
        public let status: String
        public let running: Bool
        public let paused: Bool
        public let restarting: Bool
        public let oomKilled: Bool
        public let dead: Bool
        public let exitCode: Int
        public let error: String
        public let startedAt: Date?
        /// Nil for a container that has not finished. The engine sends the Go
        /// zero time here, which is why this goes through
        /// `ThrallEngineTimestamp`.
        public let finishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case status = "Status", running = "Running", paused = "Paused"
            case restarting = "Restarting", oomKilled = "OOMKilled", dead = "Dead"
            case exitCode = "ExitCode", error = "Error"
            case startedAt = "StartedAt", finishedAt = "FinishedAt"
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            status = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
            running = try values.decodeIfPresent(Bool.self, forKey: .running) ?? false
            paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            restarting = try values.decodeIfPresent(Bool.self, forKey: .restarting) ?? false
            oomKilled = try values.decodeIfPresent(Bool.self, forKey: .oomKilled) ?? false
            dead = try values.decodeIfPresent(Bool.self, forKey: .dead) ?? false
            exitCode = try values.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
            error = try values.decodeIfPresent(String.self, forKey: .error) ?? ""
            startedAt = ThrallEngineTimestamp.parse(
                try values.decodeIfPresent(String.self, forKey: .startedAt))
            finishedAt = ThrallEngineTimestamp.parse(
                try values.decodeIfPresent(String.self, forKey: .finishedAt))
        }
    }

    public struct RestartPolicy: Decodable, Equatable, Sendable {
        /// `no`, `always`, `unless-stopped`, `on-failure`.
        public let name: String
        public let maximumRetryCount: Int

        /// A container the engine will not restart cannot be in a crash loop,
        /// and checking this first is what keeps a one-shot job that exited 1
        /// out of the triage feed.
        public var canRestart: Bool { !name.isEmpty && name != "no" }

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case maximumRetryCount = "MaximumRetryCount"
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? "no"
            maximumRetryCount = try values.decodeIfPresent(Int.self, forKey: .maximumRetryCount) ?? 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", created = "Created"
        case restartCount = "RestartCount", state = "State"
        case hostConfig = "HostConfig", config = "Config"
    }

    private enum HostConfigKeys: String, CodingKey { case restartPolicy = "RestartPolicy" }
    private enum ConfigKeys: String, CodingKey { case tty = "Tty" }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let rawName = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        created = ThrallEngineTimestamp.parse(
            try values.decodeIfPresent(String.self, forKey: .created))
        restartCount = try values.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0
        state = try values.decode(State.self, forKey: .state)

        if let hostConfig = try? values.nestedContainer(keyedBy: HostConfigKeys.self,
                                                        forKey: .hostConfig) {
            restartPolicy = try hostConfig.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy)
                ?? RestartPolicy(name: "no", maximumRetryCount: 0)
        } else {
            restartPolicy = RestartPolicy(name: "no", maximumRetryCount: 0)
        }
        if let config = try? values.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config) {
            hasTTY = try config.decodeIfPresent(Bool.self, forKey: .tty) ?? false
        } else {
            hasTTY = false
        }
    }
}

extension ThrallContainerInspectDTO.RestartPolicy {
    init(name: String, maximumRetryCount: Int) {
        self.name = name
        self.maximumRetryCount = maximumRetryCount
    }
}
