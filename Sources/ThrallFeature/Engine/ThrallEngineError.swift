import Foundation

/// Failures that belong to the engine conversation rather than to the socket.
public enum ThrallEngineError: Error, Equatable, Sendable {
    /// The selected context names a transport Thrall will not drive.
    case unsupportedEndpoint(reason: String)
    /// No context resolved — a `currentContext` naming nothing in the store.
    case noEngineSelected(name: String)
    /// `/version` did not answer with a version this build can read.
    case versionUnreadable(detail: String)
    /// The engine is older than the floor. Fail closed: half the endpoints
    /// Thrall needs did not exist before 1.41.
    case apiTooOld(reported: String, minimumSupported: String)
    /// The version we would pin is below what the server will serve.
    case apiNotServable(chosen: String, serverMinimum: String)
    /// A 4xx/5xx with the engine's own `{"message": ...}` where it sent one.
    case http(status: Int, message: String)
    /// The body did not decode. Carries the type so the log names the shape
    /// that changed, which is the only useful thing to know here.
    case decoding(type: String, detail: String)
}
