import Foundation

/// One engine context, as the switcher chip will show it.
public struct ThrallEngineContext: Equatable, Hashable, Sendable, Identifiable {
    /// Where this context's endpoint came from. Shown in the engine panel,
    /// because "why is Thrall talking to *that* daemon" is otherwise
    /// unanswerable — and with `DOCKER_HOST` set, the answer is never the
    /// context the user thinks is current.
    public enum Source: Equatable, Hashable, Sendable {
        /// `DOCKER_HOST` in the environment. Overrides every context.
        case environment
        /// A `contexts/meta/<sha256>/meta.json` under the Docker config dir.
        case contextStore
        /// The implicit `default` context, i.e. the platform socket path.
        case platformDefault
    }

    public let name: String
    public let description: String?
    public let endpoint: ThrallEngineEndpoint
    public let source: Source

    public var id: String { name }
    public var isSupported: Bool { endpoint.isSupported }

    public init(name: String,
                description: String? = nil,
                endpoint: ThrallEngineEndpoint,
                source: Source) {
        self.name = name
        self.description = description
        self.endpoint = endpoint
        self.source = source
    }
}
