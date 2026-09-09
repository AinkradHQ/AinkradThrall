import Foundation

/// A bidirectional byte pipe. The seam that keeps every parser in this folder
/// testable with no daemon: `ThrallConnection` is the only conformer that
/// touches a socket, and `ScriptedByteStream` in the tests is the one that
/// replays captured bytes — including replays that split a frame across reads
/// in the exact place that used to break it.
public protocol ThrallByteStream: Sendable {
    func connect() async throws
    func send(_ bytes: Data) async throws
    /// Reads whatever is available, blocking until at least one byte is.
    ///
    /// `timeout` is explicit at every call site, with no default, because the
    /// right value differs by kind of read rather than by connection: a unary
    /// `GET /containers/json` that goes quiet is broken, while `/events` and a
    /// `follow` log stream are legitimately silent for minutes and must pass
    /// `nil`. A shared default would be wrong for one of them, and the wrong
    /// one is the streaming case — where a spurious timeout looks like the
    /// engine dying.
    ///
    /// A `nil` timeout still terminates: `close()` fails every suspended read,
    /// and cancelling the calling task tears the connection down.
    func read(timeout: Duration?) async throws -> Data
    func close() async
}
