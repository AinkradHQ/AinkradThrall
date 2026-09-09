import Foundation

/// Everything the transport layer can fail with.
///
/// Deliberately small and closed. Each case exists because a caller upstream
/// treats it differently: `.closed` on a follow stream is normal end-of-stream
/// and gets a reconnect, `.malformedResponse` means we are desynced from the
/// wire and reconnecting is the *only* safe recovery, and
/// `.unsupportedFraming` must never be papered over — see
/// `ThrallLogFrameDecoder`, where guessing the framing renders garbage.
public enum ThrallTransportError: Error, Equatable, Sendable {
    /// No connection has been established yet (or it was already torn down).
    case notConnected
    /// The peer closed, or `close()` was called. On a streaming endpoint this
    /// is the ordinary terminal state, not a bug.
    case closed
    /// A connect, send or read exceeded its budget.
    case timedOut
    /// `NWConnection` reported a failure; the string is its description.
    case connectionFailed(String)
    /// The bytes on the wire do not parse. Recovery is a fresh connection:
    /// once framing is lost there is no resynchronisation point in HTTP/1.1.
    case malformedResponse(String)
    /// A declared length, header block or buffered line exceeded its cap.
    /// A separate case from `.malformedResponse` because it is the one failure
    /// that a *well-formed* peer can cause, so it is worth seeing in a log as
    /// its own thing rather than as "the daemon is broken".
    case tooLarge(String)
    /// The request could not be encoded — a control character in a path, a
    /// non-token method. Caught before a byte leaves the process.
    case invalidRequest(String)
    /// The response is framed in a way this build cannot read, e.g. a log
    /// stream with an unrecognised `Content-Type`.
    case unsupportedFraming(String)
}
