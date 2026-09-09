import Foundation
import Network

/// One `NWConnection` over an AF_UNIX socket — the only type in Thrall that
/// touches the wire. It knows nothing about HTTP: bytes in, bytes out, close.
/// Everything with logic in it lives above this seam and is tested against
/// `ScriptedByteStream`.
///
/// **Why `Network.framework` and not POSIX or swift-nio.** A plugin bundle
/// must statically link every runtime dependency that is not `AinkradAppKit`,
/// which prices out AsyncHTTPClient (nine static products plus BoringSSL as C
/// targets). Network.framework is a system framework, so it costs nothing to
/// link and still gives AF_UNIX through one endpoint type. Hand-rolled POSIX
/// would mean one parked thread per open stream — with `/events` plus a log
/// follow per visible stack that is the thread starvation `GitRepositoryClient`
/// documents. `NWConnection(to: .unix(path:), using: .tcp)` was compiled and
/// run against this machine's OrbStack socket before any of this was built.
///
/// **The continuation discipline is copied verbatim from
/// `AinkradRaven`'s `NetworkTransport`, which earned it:**
///
///  1. Every `NWConnection` callback, every timeout and every state mutation
///     runs on ONE private serial queue, so the mutable state below really is
///     single-queue confined and `@unchecked Sendable` describes a mechanism
///     rather than a hope. Timeouts are `DispatchWorkItem`s on that same
///     queue, never an unstructured `Task` — which would run on the concurrent
///     executor and race the callbacks.
///  2. Every suspended call resumes through a `ThrallOneShotResumeGuard`, so a
///     callback arriving after a timeout, a `close()` or a cancellation is a
///     no-op instead of a double resume.
///  3. Every pending call is registered in `waiters` *before* it can suspend,
///     so `close()`, a connection failure, task cancellation and `deinit` can
///     all fail it. A `read(timeout: nil)` on a quiet `/events` stream that
///     could not be failed would hang plugin teardown forever, with no timeout
///     able to break it.
public final class ThrallConnection: ThrallByteStream, @unchecked Sendable {
    /// One suspended call. Identity is the object, so a completed call removes
    /// exactly its own entry. `@unchecked Sendable` because every field is
    /// touched on `queue` only and `fail` resumes through a lock-protected
    /// guard.
    private final class Waiter: @unchecked Sendable {
        let fail: @Sendable (ThrallTransportError) -> Void
        var timeout: DispatchWorkItem?
        init(fail: @escaping @Sendable (ThrallTransportError) -> Void) { self.fail = fail }
    }

    private let socketPath: String
    private let connectTimeout: Duration
    private let queue = DispatchQueue(label: "com.ainkrad.thrall.connection")
    private var connection: NWConnection?
    private var isClosed = false
    private var waiters: [Waiter] = []
    /// Whoever is waiting for the connection to become usable. Populated by
    /// `connect()` and fired by `.ready`. Failures do not come through here —
    /// they come through `failAll`, so one teardown path covers every
    /// suspended call.
    private var readyWaiters: [@Sendable () -> Void] = []

    public init(socketPath: String, connectTimeout: Duration = .seconds(10)) {
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
    }

    deinit {
        // Hard backstop, unreachable while ownership above is correct: a future
        // bug surfaces as a definite error rather than a hang.
        let stranded = waiters
        waiters = []
        for waiter in stranded { waiter.fail(.closed) }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    // MARK: - ThrallByteStream

    public func connect() async throws {
        try await withTaskCancellationHandler {
            // `[self]` is explicit so the `[weak self]` captures below read as
            // a deliberate difference from the enclosing scope rather than an
            // accidental one.
            try await suspendVoid { [self] guard_ in
                guard !self.isClosed else { guard_.fire(.failure(.closed)); return }
                guard self.connection == nil else { guard_.fire(.success(())); return }

                let connection = NWConnection(to: .unix(path: self.socketPath), using: .tcp)
                self.connection = connection

                let waiter = self.register { guard_.fire(.failure($0)) }
                self.scheduleTimeout(self.connectTimeout, on: waiter) { [weak self] in
                    self?.discard(waiter)
                    self?.teardown(.timedOut)
                    guard_.fire(.failure(.timedOut))
                }
                self.readyWaiters.append { [weak self] in
                    waiter.timeout?.cancel()
                    self?.discard(waiter)
                    guard_.fire(.success(()))
                }
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.fireReady()
                    case .failed(let error):
                        // Fails every other suspended call too; this is the
                        // path that would otherwise strand a read.
                        self.teardown(.connectionFailed("\(error)"))
                    case .waiting(let error):
                        // **Treated as a failure on purpose.** For AF_UNIX
                        // there is no network path to wait for: `.waiting`
                        // means the socket file is missing or nothing is
                        // listening — i.e. the engine is not running.
                        // Network.framework would retry that indefinitely, so
                        // an engine-down connect would hang until the connect
                        // timeout instead of answering in milliseconds. Retry
                        // policy belongs to the caller's backoff, not here.
                        self.teardown(.connectionFailed("\(error)"))
                    case .cancelled:
                        self.teardown(.closed)
                    default:
                        break
                    }
                }
                connection.start(queue: self.queue)
            }
        } onCancel: {
            cancelEverything()
        }
    }

    public func send(_ bytes: Data) async throws {
        try await withTaskCancellationHandler {
            try await suspendVoid { [self] guard_ in
                guard !self.isClosed, let connection = self.connection else {
                    guard_.fire(.failure(self.isClosed ? .closed : .notConnected))
                    return
                }
                let waiter = self.register { guard_.fire(.failure($0)) }
                connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    self?.discard(waiter)
                    if let error {
                        guard_.fire(.failure(.connectionFailed("\(error)")))
                    } else {
                        guard_.fire(.success(()))
                    }
                })
            }
        } onCancel: {
            cancelEverything()
        }
    }

    public func read(timeout: Duration?) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let guard_ = ThrallOneShotResumeGuard<Result<Data, ThrallTransportError>> { result in
                    switch result {
                    case .success(let data): continuation.resume(returning: data)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                queue.async { [self] in
                    guard !self.isClosed, let connection = self.connection else {
                        guard_.fire(.failure(self.isClosed ? .closed : .notConnected))
                        return
                    }
                    let waiter = self.register { guard_.fire(.failure($0)) }
                    if let timeout {
                        self.scheduleTimeout(timeout, on: waiter) { [weak self] in
                            self?.discard(waiter)
                            guard_.fire(.failure(.timedOut))
                        }
                    }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                        [weak self] data, _, isComplete, error in
                        waiter.timeout?.cancel()
                        self?.discard(waiter)
                        if let error {
                            guard_.fire(.failure(.connectionFailed("\(error)")))
                            return
                        }
                        if let data, !data.isEmpty {
                            guard_.fire(.success(data))
                            return
                        }
                        // Empty data with `isComplete` is a clean peer close;
                        // empty without it cannot be told apart usefully.
                        // Either way `.closed` keeps a caller from spinning on
                        // zero-byte reads — and for a `Connection: close`
                        // response with no declared length, this IS the
                        // terminator the parser is waiting for.
                        _ = isComplete
                        guard_.fire(.failure(.closed))
                    }
                }
            }
        } onCancel: {
            cancelEverything()
        }
    }

    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.teardown(.closed)
                continuation.resume()
            }
        }
    }

    // MARK: - Queue-confined helpers (every one of these runs on `queue` only)

    /// Cancellation path: hop to the queue and tear down. Not a `Task`, because
    /// an unstructured task runs on the concurrent executor and would race the
    /// callbacks this must be ordered against. Tearing the whole connection
    /// down is the right blast radius: Thrall opens one connection per
    /// request, so the cancelled task is its only user.
    private func cancelEverything() {
        queue.async { self.teardown(.closed) }
    }

    private func suspendVoid(
        _ body: @escaping @Sendable (ThrallOneShotResumeGuard<Result<Void, ThrallTransportError>>) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let guard_ = ThrallOneShotResumeGuard<Result<Void, ThrallTransportError>> { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            queue.async { body(guard_) }
        }
    }

    private func register(fail: @escaping @Sendable (ThrallTransportError) -> Void) -> Waiter {
        let waiter = Waiter(fail: fail)
        waiters.append(waiter)
        return waiter
    }

    private func discard(_ waiter: Waiter) {
        waiters.removeAll { $0 === waiter }
    }

    /// Releases whoever is waiting for `.ready`. Drained before firing so a
    /// handler that registers a new waiter is not fired by the event that
    /// released the previous one.
    private func fireReady() {
        let pending = readyWaiters
        readyWaiters = []
        for fire in pending { fire() }
    }

    /// Fails every suspended call and kills the socket. Idempotent, and safe
    /// to call from the timeout path, the state handler, `close()` and the
    /// cancellation handler — each `fire` is a no-op if that call already
    /// resumed.
    private func teardown(_ error: ThrallTransportError) {
        isClosed = true
        readyWaiters = []
        let stranded = waiters
        waiters = []
        for waiter in stranded { waiter.fail(error) }
        connection?.stateUpdateHandler = nil
        // An uncancelled NWConnection keeps a socket AND a dispatch source
        // alive, which would go on waking the CPU after Thrall's window closed.
        connection?.cancel()
        connection = nil
    }

    private func scheduleTimeout(_ duration: Duration,
                                 on waiter: Waiter,
                                 _ body: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem(block: body)
        waiter.timeout = item
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
