import Foundation

/// The byte pipe left behind by a `101 Switching Protocols` — what
/// `POST /containers/{id}/attach` and `/exec/{id}/start` hand back.
///
/// Its entire reason for existing is the `residual`. The engine's upgrade
/// response and the container's first output arrive in the **same** read, so
/// whatever sat past the header terminator is already payload. Handing the raw
/// connection to the caller instead loses those bytes — which is the first
/// line of a shell prompt, or the whole of a short command's output, missing
/// only when the timing lines up. That is a bug that reproduces once a week
/// and never on demand, so the residual is a constructor argument rather than
/// something a call site is trusted to remember.
actor ThrallHijackedStream: ThrallByteStream {
    private let upstream: any ThrallByteStream
    /// Nil once handed out. Not appended to a buffer, so the first read after
    /// an upgrade returns exactly the bytes the engine already sent rather
    /// than waiting for more.
    private var residual: Data?

    init(upstream: any ThrallByteStream, residual: Data) {
        self.upstream = upstream
        self.residual = residual.isEmpty ? nil : residual
    }

    /// A no-op: the connection under this one is already open and upgraded.
    func connect() async throws {}

    func send(_ bytes: Data) async throws {
        try await upstream.send(bytes)
    }

    func read(timeout: Duration?) async throws -> Data {
        if let pending = residual {
            residual = nil
            return pending
        }
        return try await upstream.read(timeout: timeout)
    }

    func close() async {
        residual = nil
        await upstream.close()
    }
}
