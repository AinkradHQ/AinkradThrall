import Foundation

/// Reads the Docker CLI's own context store and answers two questions: which
/// engines exist, and which one is current.
///
/// It reproduces the CLI's precedence rather than inventing one, because the
/// user's `docker ps` and Thrall's list must agree or neither is trustworthy:
///
///   1. **`DOCKER_HOST` wins outright.** When it is set, the CLI ignores the
///      context store entirely — `currentContext` becomes decoration. Thrall
///      says so in the switcher instead of showing a context it is not using.
///   2. Then `DOCKER_CONTEXT`.
///   3. Then `currentContext` from `config.json`.
///   4. Then the implicit `default`.
///
/// **A named context that is missing from the store resolves to nothing, not
/// to `default`.** Falling back would silently drive a different daemon —
/// which, with three contexts configured here, is a real way to stop the wrong
/// database.
///
/// The store's directory names are `sha256(contextName)` (verified against all
/// contexts on this machine), so a named lookup could skip the scan. The scan
/// stays because listing needs it anyway and one pass answers both questions.
public struct ThrallContextResolver: Sendable {
    public struct Resolution: Equatable, Sendable {
        /// Every context found, `default` first and the rest alphabetical.
        public let contexts: [ThrallEngineContext]
        /// The name the precedence rules selected, whether or not it resolved.
        public let activeName: String
        /// The selected context, or nil when the name names nothing usable.
        public let active: ThrallEngineContext?
        /// Human-readable reasons anything was skipped or overridden. Surfaced
        /// in the engine panel; a silently dropped context is a support call.
        public let notes: [String]
    }

    /// Docker's config directory — `~/.docker` in production, a temporary
    /// directory in tests. Injected rather than derived so the resolver never
    /// needs the real one to be testable.
    public let configDirectory: URL
    public let environment: [String: String]
    /// The platform socket for the implicit `default` context.
    public let platformSocketPath: String

    public init(configDirectory: URL,
                environment: [String: String],
                platformSocketPath: String = "/var/run/docker.sock") {
        self.configDirectory = configDirectory
        self.environment = environment
        self.platformSocketPath = platformSocketPath
    }

    public static func system(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> ThrallContextResolver {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = environment["DOCKER_CONFIG"].flatMap { value -> URL? in
            value.isEmpty ? nil : URL(fileURLWithPath: value)
        }
        return ThrallContextResolver(configDirectory: configured
                                        ?? home.appendingPathComponent(".docker"),
                                     environment: environment)
    }

    public func resolve() -> Resolution {
        var notes: [String] = []
        let stored = storedContexts(notes: &notes)

        let environmentHost = environment["DOCKER_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        var defaultEndpoint = ThrallEngineEndpoint.unixSocket(path: platformSocketPath)
        var defaultSource = ThrallEngineContext.Source.platformDefault
        var environmentWins = false

        if let environmentHost {
            if let parsed = ThrallEngineEndpoint.parse(environmentHost) {
                defaultEndpoint = parsed
                defaultSource = .environment
                environmentWins = true
                notes.append("DOCKER_HOST is set to \(environmentHost), which overrides the "
                    + "current context.")
            } else {
                notes.append("DOCKER_HOST is set to \(environmentHost), which names no endpoint "
                    + "Thrall understands; falling back to the context store.")
            }
        }

        let defaultContext = ThrallEngineContext(
            name: "default",
            description: environmentWins ? "From DOCKER_HOST" : "Platform default",
            endpoint: defaultEndpoint,
            source: defaultSource)

        let contexts = [defaultContext] + stored.sorted { $0.name < $1.name }

        let activeName: String
        if environmentWins {
            activeName = "default"
        } else if let named = environment["DOCKER_CONTEXT"], !named.isEmpty {
            activeName = named
            notes.append("DOCKER_CONTEXT selects \(named).")
        } else if let current = currentContextName() {
            activeName = current
        } else {
            activeName = "default"
        }

        let active = contexts.first { $0.name == activeName }
        if active == nil {
            notes.append("The selected context \(activeName) is not in the context store. "
                + "Thrall will not guess at another engine.")
        } else if let active, !active.isSupported, case .unsupported(_, _, let reason) = active.endpoint {
            notes.append("\(active.name) is \(reason).")
        }

        return Resolution(contexts: contexts,
                          activeName: activeName,
                          active: active,
                          notes: notes)
    }

    // MARK: - Disk

    private func currentContextName() -> String? {
        let url = configDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["currentContext"] as? String, !current.isEmpty else {
            return nil
        }
        return current
    }

    private func storedContexts(notes: inout [String]) -> [ThrallEngineContext] {
        let metaRoot = configDirectory.appendingPathComponent("contexts/meta")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: metaRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [ThrallEngineContext] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let metaURL = entry.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = root["Name"] as? String, !name.isEmpty else {
                continue
            }
            // `default` is synthesised, never read from the store, so a stray
            // entry claiming that name cannot shadow it.
            guard name != "default" else { continue }

            let endpoints = root["Endpoints"] as? [String: Any]
            guard let docker = endpoints?["docker"] as? [String: Any],
                  let host = docker["Host"] as? String else {
                notes.append("Context \(name) declares no docker endpoint; skipped.")
                continue
            }
            guard let endpoint = ThrallEngineEndpoint.parse(host) else {
                notes.append("Context \(name) has an unreadable host (\(host)); skipped.")
                continue
            }
            let metadata = root["Metadata"] as? [String: Any]
            found.append(ThrallEngineContext(name: name,
                                             description: metadata?["Description"] as? String,
                                             endpoint: endpoint,
                                             source: .contextStore))
        }
        return found
    }
}
