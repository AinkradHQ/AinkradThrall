import Foundation
import Testing

@testable import ThrallFeature

/// A reply that arrives only after `delay`, honouring the read timeout and
/// cancellation the way `ThrallConnection` does (timeout -> `.timedOut`,
/// cancellation -> `.closed`).
private actor SlowByteStream: ThrallByteStream {
    private var pending: [Data]
    private let delay: Duration
    private var first = true
    init(_ response: Data, delay: Duration) {
        pending = [response]
        self.delay = delay
    }
    func connect() async throws {}
    func send(_ bytes: Data) async throws {}
    func read(timeout: Duration?) async throws -> Data {
        if first {
            first = false
            do {
                if let timeout, timeout < delay {
                    try await Task.sleep(for: timeout)
                    throw ThrallTransportError.timedOut
                }
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                throw ThrallTransportError.closed
            }
        }
        guard !pending.isEmpty else { throw ThrallTransportError.closed }
        return pending.removeFirst()
    }
    func close() async {}
}

/// version, then df (slow), then networks, then silence.
private final class SlowDFEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(Data, Duration)] = [
        (ScriptedEngine.versionResponse, .zero),
        (ScriptedEngine.response(#"{"LayersSize":0,"Images":[],"BuildCache":[],"Volumes":[]}"#), .milliseconds(300)),
        (ScriptedEngine.response("[]"), .zero),
    ]
    private(set) var requests = 0
    var factory: ThrallEngineClient.StreamFactory {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            requests += 1
            let next = script.isEmpty ? (Data(), Duration.zero) : script.removeFirst()
            return SlowByteStream(next.0, delay: next.1)
        }
    }
}

@MainActor
@Suite("system/df on a slow engine")
struct ThrallSlowDiskUsageTests {
    private func client(_ engine: SlowDFEngine) throws -> ThrallEngineClient {
        // A unary timeout far below the df delay: df must not inherit it.
        try ThrallEngineClient(
            endpoint: .unixSocket(path: "/tmp/thrall-test.sock"),
            requestTimeout: .milliseconds(50),
            streamFactory: engine.factory)
    }

    @Test("df waits longer than the unary request timeout")
    func dfOutlivesRequestTimeout() async throws {
        let usage = try await client(SlowDFEngine()).diskUsage()
        #expect(usage.images.isEmpty)
    }

    @Test("a cancelled view task neither errors the model nor stops the read")
    func cancelledCallerDoesNotPoisonLoad() async throws {
        let engine = SlowDFEngine()
        let client = try client(engine)
        let model = ThrallStorageModel()

        let first = Task { await model.load(client: client) }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()  // the user clicked to another area
        await model.load(client: client)  // that area's own load

        #expect(model.error == nil)
        #expect(model.usage != nil)
        #expect(!model.isLoading)
        // version + df + networks: one df read, not two.
        #expect(engine.requests == 3)
    }

    @Test("a failed reload drops the old snapshot so counts never sit beside an error")
    func failureClearsUsage() async throws {
        let engine = SlowDFEngine()
        let client = try client(engine)
        let model = ThrallStorageModel()
        await model.load(client: client)
        #expect(model.usage != nil)

        await model.load(client: client, force: true)  // script exhausted: engine goes quiet
        #expect(model.error != nil)
        #expect(model.usage == nil)
        #expect(model.loadedAt == nil)
        #expect(!model.isLoading)
    }
}
