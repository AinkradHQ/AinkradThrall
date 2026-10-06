import Foundation

/// One engine context, as the switcher chip will show it.
struct ThrallEngineContext: Equatable, Hashable, Sendable, Identifiable {
    let name: String
    let description: String?
    let endpoint: ThrallEngineEndpoint

    var id: String { name }
    var isSupported: Bool { endpoint.isSupported }

    init(
        name: String,
        description: String? = nil,
        endpoint: ThrallEngineEndpoint
    ) {
        self.name = name
        self.description = description
        self.endpoint = endpoint
    }
}
