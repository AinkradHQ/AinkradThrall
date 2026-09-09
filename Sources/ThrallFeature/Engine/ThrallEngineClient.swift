import Foundation

/// `GET /version`, which is answered unversioned.
struct ThrallVersionDTO: Decodable {
    struct Platform: Decodable { let name: String?
        enum CodingKeys: String, CodingKey { case name = "Name" } }

    let version: String?
    let apiVersion: String?
    let minAPIVersion: String?
    let os: String?
    let arch: String?
    let platform: Platform?

    enum CodingKeys: String, CodingKey {
        case version = "Version", apiVersion = "ApiVersion", minAPIVersion = "MinAPIVersion"
        case os = "Os", arch = "Arch", platform = "Platform"
    }
}

/// Unary reads against one engine.
///
/// **Unary only, on purpose.** Nothing here opens a long-lived socket; the
/// events stream and log follows belong to a single stream supervisor (Task E)
/// so that teardown is one call rather than a search for whatever forgot to
/// close. Each request gets a fresh connection from `streamFactory`, matching
/// `ThrallHTTPRequest`'s `Connection: close`.
///
/// The version prefix is **negotiated once, lazily, then reused.** Every read
/// pays for the handshake the first time and nothing after, and no path in
/// this file contains a hardcoded `/v1.xx`.
public actor ThrallEngineClient {
    /// Produces a fresh byte stream per request. Injected so the whole client
    /// is testable against `ScriptedByteStream` with no daemon.
    public typealias StreamFactory = @Sendable () -> any ThrallByteStream

    public let endpoint: ThrallEngineEndpoint
    /// `internal` rather than `private` so the log read in
    /// `ThrallEngineClient+Logs` can open its own connection — a log tail is
    /// framed differently from every other response and needs the raw
    /// reader, not the unary JSON path.
    let makeStream: StreamFactory
    let requestTimeout: Duration
    private var cachedVersion: ThrallEngineVersion?

    public init(endpoint: ThrallEngineEndpoint,
                requestTimeout: Duration = .seconds(30),
                streamFactory: StreamFactory? = nil) throws {
        guard case .unixSocket(let path) = endpoint else {
            if case .unsupported(_, _, let reason) = endpoint {
                throw ThrallEngineError.unsupportedEndpoint(reason: reason)
            }
            throw ThrallEngineError.unsupportedEndpoint(reason: "unrecognised endpoint")
        }
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
        self.makeStream = streamFactory ?? { ThrallConnection(socketPath: path) }
    }

    // MARK: - Handshake

    /// Probes and negotiates, caching the result.
    @discardableResult
    public func version() async throws -> ThrallEngineVersion {
        if let cachedVersion { return cachedVersion }
        // Unversioned: a version probe that needs a version is a bootstrap
        // problem.
        let dto: ThrallVersionDTO = try await get(target: "/version")
        guard let raw = dto.apiVersion, let reported = ThrallAPIVersion(raw) else {
            throw ThrallEngineError.versionUnreadable(
                detail: "ApiVersion was \(dto.apiVersion ?? "absent")")
        }
        let serverMinimum = dto.minAPIVersion.flatMap(ThrallAPIVersion.init)
        let negotiated = try ThrallEngineNegotiation.negotiate(reported: reported,
                                                              serverMinimum: serverMinimum)
        let resolved = ThrallEngineVersion(engineVersion: dto.version ?? "unknown",
                                           apiVersion: reported,
                                           minimumAPIVersion: serverMinimum,
                                           platformName: dto.platform?.name,
                                           os: dto.os ?? "",
                                           arch: dto.arch ?? "",
                                           negotiated: negotiated)
        cachedVersion = resolved
        return resolved
    }

    // MARK: - Reads

    /// `all: true` is the default because a stack whose containers have all
    /// exited must still have a row — that is 28 of the 48 containers here,
    /// and the entire `aai1058` stack.
    public func containers(all: Bool = true) async throws -> [ThrallContainerDTO] {
        try await versioned(path: "/containers/json", query: all ? [("all", "1")] : [])
    }

    public func inspect(containerID: String) async throws -> ThrallContainerInspectDTO {
        try await versioned(path: "/containers/\(try Self.identifier(containerID))/json")
    }

    /// `shared-size` is left off: it costs a full layer walk, and
    /// `ThrallImageDTO.computedSharedSize` reports the `-1` sentinel as nil so
    /// nothing sums it by accident.
    public func images() async throws -> [ThrallImageDTO] {
        try await versioned(path: "/images/json", query: [("all", "0")])
    }

    public func volumes() async throws -> ThrallVolumeListDTO {
        try await versioned(path: "/volumes")
    }

    public func networks() async throws -> [ThrallNetworkDTO] {
        try await versioned(path: "/networks")
    }

    /// One call, and the only source of volume sizes — `/volumes` reports
    /// none.
    ///
    /// **Measured at 1.86 s against this machine, versus <=0.2 s for every
    /// other read** (version 0.10, containers 0.15, images 0.20, volumes and
    /// networks 0.01). It walks 289 build-cache entries and 135 volumes to get
    /// there. So this must never sit on the 10 s reconcile poll or on a view's
    /// `.task` — it is an explicit, on-demand call for the storage area, with
    /// the result cached above this layer.
    public func diskUsage() async throws -> ThrallDiskUsageDTO {
        try await versioned(path: "/system/df")
    }

    // MARK: - Writes

    /// Engine-level container verbs.
    ///
    /// These exist for the **orphaned stack**: `aai1058`'s compose files are
    /// gone, so `docker compose` cannot touch it at all — it needs the file it
    /// was started from. Stopping and starting containers by id is what makes
    /// the largest broken stack on this machine actionable rather than merely
    /// visible.
    ///
    /// Deliberately absent: any form of *remove*. Container removal is on its
    /// own explicit path, never a side effect of a lifecycle verb.
    public func start(containerID: String) async throws {
        try await post(path: "/containers/\(try Self.identifier(containerID))/start",
                       // 304 means "already started", which is success from the
                       // caller's point of view and must not read as an error.
                       accepting: [204, 304])
    }

    public func stop(containerID: String, timeoutSeconds: Int = 10) async throws {
        try await post(path: "/containers/\(try Self.identifier(containerID))/stop",
                       query: [("t", String(timeoutSeconds))],
                       accepting: [204, 304])
    }

    public func restart(containerID: String, timeoutSeconds: Int = 10) async throws {
        try await post(path: "/containers/\(try Self.identifier(containerID))/restart",
                       query: [("t", String(timeoutSeconds))],
                       accepting: [204])
    }

    private func post(path: String,
                      query: [(String, String)] = [],
                      accepting: Set<Int>) async throws {
        let prefix = try await version().pathPrefix
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(method: "POST",
                              target: Self.target(prefix + path, query: query)),
            over: makeStream(),
            timeout: requestTimeout)
        guard accepting.contains(response.head.statusCode) else {
            let message = (try? JSONDecoder().decode(ThrallEngineMessageDTO.self,
                                                     from: response.body))?.message
            throw ThrallEngineError.http(status: response.head.statusCode,
                                         message: message ?? response.head.reasonPhrase)
        }
    }

    // MARK: - Plumbing

    private func versioned<Value: Decodable>(path: String,
                                             query: [(String, String)] = []) async throws -> Value {
        let prefix = try await version().pathPrefix
        return try await get(target: Self.target(prefix + path, query: query))
    }

    private func get<Value: Decodable>(target: String) async throws -> Value {
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(target: target),
            over: makeStream(),
            timeout: requestTimeout)

        guard response.head.isSuccess else {
            // The engine puts a usable sentence in `{"message": ...}`. Falling
            // back to the reason phrase keeps the error readable when it does
            // not (a proxy 502, say).
            let message = (try? JSONDecoder().decode(ThrallEngineMessageDTO.self,
                                                     from: response.body))?.message
            throw ThrallEngineError.http(status: response.head.statusCode,
                                         message: message ?? response.head.reasonPhrase)
        }
        do {
            return try JSONDecoder().decode(Value.self, from: response.body)
        } catch {
            throw ThrallEngineError.decoding(type: "\(Value.self)", detail: "\(error)")
        }
    }

    /// Builds a request target with the query percent-encoded.
    ///
    /// `/events`' `filters` parameter is JSON — braces, quotes, brackets — so
    /// the encoding cannot be skipped, and `ThrallHTTPRequest` refuses an
    /// unencoded target rather than encoding it for us.
    static func target(_ path: String, query: [(String, String)]) -> String {
        guard !query.isEmpty else { return path }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = query.map { item in
            item.0.addingPercentEncoding(withAllowedCharacters: allowed)!
                + "=" + item.1.addingPercentEncoding(withAllowedCharacters: allowed)!
        }
        return path + "?" + pairs.joined(separator: "&")
    }

    /// Container and image identifiers go straight into a path, so they are
    /// checked against compose's own identifier rule. Without this, a name
    /// containing `../` would address a different endpoint entirely.
    static func identifier(_ raw: String) throws -> String {
        let allowed = { (character: Character) -> Bool in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "_" || character == "." || character == "-")
        }
        guard !raw.isEmpty, raw.count <= 255, raw.allSatisfy(allowed),
              let first = raw.first, first.isASCII, first.isLetter || first.isNumber else {
            throw ThrallEngineError.decoding(type: "identifier",
                                             detail: "\(raw.debugDescription) is not a container id or name")
        }
        return raw
    }
}
