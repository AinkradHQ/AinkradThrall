import Foundation

/// Owns the `/events` stream, and is **the only thing in Thrall that opens a
/// long-lived socket**.
///
/// That is what makes teardown one call. Every unary read gets a fresh
/// connection and closes it; if any other type could hold a stream open,
/// shutting Thrall down would become a search for whatever forgot to close.
///
/// ## Server-side filtering is mandatory, not an optimisation
///
/// Unfiltered, this machine produced 256 events in an hour and **every one**
/// was a healthcheck exec. Filtering server-side (verified honoured) means the
/// socket stays quiet until something actually happens, instead of waking the
/// CPU several times a second to discard its own traffic.
///
/// ## Reconnect, because the stream dies silently
///
/// An engine restart drops the events socket with no error the UI could show.
/// A purely event-driven surface then freezes on stale state forever. So this
/// reconnects with jittered backoff — and the view model's 10 s poll is the
/// floor underneath it, which converges even if every reconnect fails.
public actor ThrallStreamSupervisor {
    public typealias EventHandler = @Sendable (ThrallEvent) async -> Void
    /// Called whenever the stream (re)connects or drops, so the UI can say so.
    public typealias StateHandler = @Sendable (Bool) async -> Void

    private let socketPath: String
    private let apiVersion: ThrallAPIVersion
    private let streamFactory: @Sendable () -> any ThrallByteStream
    private var task: Task<Void, Never>?

    public init(socketPath: String,
                apiVersion: ThrallAPIVersion,
                streamFactory: (@Sendable () -> any ThrallByteStream)? = nil) {
        self.socketPath = socketPath
        self.apiVersion = apiVersion
        self.streamFactory = streamFactory ?? { ThrallConnection(socketPath: socketPath) }
    }

    /// The `filters` value. Container lifecycle only — `exec_*` and
    /// `health_status` are excluded at the server.
    static let eventFilters = #"{"type":["container"],"#
        + #""event":["start","die","stop","kill","restart","create","destroy"]}"#

    public func start(onEvent: @escaping EventHandler,
                      onConnected: @escaping StateHandler = { _ in }) {
        guard task == nil else { return }
        task = Task { [apiVersion, streamFactory] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    try await Self.consume(apiVersion: apiVersion,
                                           stream: streamFactory(),
                                           onEvent: onEvent,
                                           onConnected: onConnected)
                    // A clean end means the peer closed: reconnect promptly
                    // rather than treating it as a failure.
                    attempt = 0
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                }
                await onConnected(false)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.backoff(attempt: attempt))
            }
        }
    }

    /// 250 ms doubling to a 30 s ceiling, with jitter.
    ///
    /// The jitter is not decoration: without it every Thrall window on the
    /// machine retries in lockstep after an engine restart, and they hammer
    /// the socket together at exactly the moment it is least able to answer.
    static func backoff(attempt: Int) -> Duration {
        let base = min(0.25 * pow(2, Double(max(0, attempt - 1))), 30)
        return .seconds(base * Double.random(in: 0.7...1.3))
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public var isRunning: Bool { task != nil }

    private static func consume(apiVersion: ThrallAPIVersion,
                                stream: any ThrallByteStream,
                                onEvent: @escaping EventHandler,
                                onConnected: @escaping StateHandler) async throws {
        let target = ThrallEngineClient.target(apiVersion.pathPrefix + "/events",
                                               query: [("filters", eventFilters)])
        try await stream.connect()
        try await stream.send(ThrallHTTPRequest(target: target).encoded())

        let reader = ThrallHTTPResponseReader(stream: stream)
        var splitter = ThrallNDJSONSplitter()
        var announced = false

        // `nil` timeout: a filtered event stream is legitimately silent for
        // minutes, and a timeout there reads to the user as the engine dying.
        // Cancellation still unblocks it — see `ThrallConnection`.
        while let event = try await reader.next(timeout: nil) {
            switch event {
            case .head(let head):
                guard head.isSuccess else {
                    throw ThrallEngineError.http(status: head.statusCode,
                                                 message: head.reasonPhrase)
                }
                if !announced {
                    announced = true
                    await onConnected(true)
                }
            case .body(let chunk):
                for line in try splitter.feed(chunk) {
                    guard let parsed = ThrallEventDTO.parse(line: line) else { continue }
                    await onEvent(parsed)
                }
            case .end:
                await stream.close()
                return
            case .trailers:
                break
            case .upgraded:
                throw ThrallTransportError.unsupportedFraming("the event stream must not upgrade")
            }
        }
        await stream.close()
    }
}
