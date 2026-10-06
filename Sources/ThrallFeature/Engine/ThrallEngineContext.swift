import Foundation

/// One engine context, as the switcher chip will show it.
public struct ThrallEngineContext: Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    public let description: String?
    public let endpoint: ThrallEngineEndpoint

    public var id: String { name }
    public var isSupported: Bool { endpoint.isSupported }

    public init(
        name: String,
        description: String? = nil,
        endpoint: ThrallEngineEndpoint
    ) {
        self.name = name
        self.description = description
        self.endpoint = endpoint
    }
}
