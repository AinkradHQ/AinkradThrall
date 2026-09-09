import Foundation

/// One record off `GET /events`.
///
/// ## The action field is not what it looks like
///
/// Measured on this machine: 256 events in an hour, **all** of them
/// `exec_create` / `exec_start` / `exec_die` from healthcheck probes, and zero
/// `die` or `start`. Worse, actions arrive **prefixed with their argument**:
///
///     "exec_create: /bin/sh -c mysqladmin ping"
///     "exec_start: /bin/sh -c mysqladmin ping"
///     "health_status: healthy"
///
/// So `action == "die"` never matches what you expect, and `exec_die` is one
/// character class away from `die`. Both hazards are handled here, once:
/// everything before the first `:` is the action, and `exec_*` is a distinct
/// case rather than something that can be mistaken for a container dying.
public struct ThrallEvent: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case start
        case die
        case stop
        case kill
        case restart
        case create
        case destroy
        case healthStatus(String)
        /// A healthcheck probe. **Never** a container lifecycle event, and
        /// 100% of this machine's event traffic.
        case exec(String)
        case other(String)
    }

    public let type: String
    public let action: Action
    public let containerID: String
    public let time: Date
    public let attributes: [String: String]

    public var isContainer: Bool { type == "container" }
    public var composeProject: String? { attributes["com.docker.compose.project"] }
    public var composeService: String? { attributes["com.docker.compose.service"] }
    public var composeWorkingDirectory: String? {
        attributes["com.docker.compose.project.working_dir"]
    }
    public var containerName: String? { attributes["name"] }
    /// Present on a `die`. The reason a crash loop can be fingerprinted at all.
    public var exitCode: Int? { attributes["exitCode"].flatMap(Int.init) }

    public init(type: String, action: Action, containerID: String, time: Date,
                attributes: [String: String]) {
        self.type = type
        self.action = action
        self.containerID = containerID
        self.time = time
        self.attributes = attributes
    }

    /// Splits the raw action string. Everything before the first `:` is the
    /// verb; the rest is its argument.
    public static func parseAction(_ raw: String) -> Action {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let verb = parts[0].trimmingCharacters(in: .whitespaces)
        let argument = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : ""
        if verb.hasPrefix("exec_") { return .exec(verb) }
        switch verb {
        case "start": return .start
        case "die": return .die
        case "stop": return .stop
        case "kill": return .kill
        case "restart": return .restart
        case "create": return .create
        case "destroy": return .destroy
        case "health_status": return .healthStatus(argument)
        default: return .other(verb)
        }
    }
}

/// Decodes one NDJSON line into a `ThrallEvent`.
struct ThrallEventDTO: Decodable {
    struct Actor: Decodable {
        let id: String?
        let attributes: [String: String]?
        enum CodingKeys: String, CodingKey { case id = "ID", attributes = "Attributes" }
    }

    let type: String?
    let action: String?
    let id: String?
    let actor: Actor?
    /// Unix seconds. `timeNano` is also sent; seconds is enough for a 120 s
    /// window and avoids a 64-bit nanosecond overflow question entirely.
    let time: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type", action = "Action", id = "id", actor = "Actor", time = "time"
    }

    func event() -> ThrallEvent? {
        guard let action, !action.isEmpty else { return nil }
        return ThrallEvent(
            type: type ?? "",
            action: ThrallEvent.parseAction(action),
            containerID: actor?.id ?? id ?? "",
            time: Date(timeIntervalSince1970: TimeInterval(time ?? 0)),
            attributes: actor?.attributes ?? [:])
    }

    /// Parses one NDJSON line, returning nil for anything unusable.
    ///
    /// A malformed event is **dropped, never thrown**. Events are
    /// authoritative for nothing — one lost event costs a history entry, while
    /// a throw would kill the stream that the whole triage feed depends on.
    static func parse(line: Data) -> ThrallEvent? {
        (try? JSONDecoder().decode(ThrallEventDTO.self, from: line))?.event()
    }
}
