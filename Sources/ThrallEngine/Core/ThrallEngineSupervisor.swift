import Foundation

/// Why a VM stopped.
enum ThrallVMStopReason: Equatable, Sendable {
    /// The guest powered itself off: our requested stop, or a `poweroff`.
    case guest
    /// The hypervisor stopped it with an error.
    case error(String)
    /// `forceStop()` pulled the plug after the grace period.
    case forced
}

/// One booted VM. The supervisor only sees this seam, so its lifecycle is
/// tested without `Virtualization.framework`.
@MainActor
protocol ThrallVirtualMachine: AnyObject {
    func start() async throws
    /// Asks the guest to shut down (a power-button press). Returns at once.
    func requestStop() throws
    /// Stops the VM immediately, like pulling the power cord.
    func forceStop() async throws
    /// Returns when the VM has stopped, at once if it already has. Any number
    /// of callers may wait.
    func waitUntilStopped() async -> ThrallVMStopReason
}

/// Keeps one VM running until told to stop.
///
/// - A VM that stops on its own is restarted after a backoff that doubles from
///   1 s to a 60 s cap. A VM that ran for `stableAfter` resets the backoff, so
///   a crash once a day never waits a minute.
/// - A configuration error (missing image file, invalid config) ends `run()`:
///   no restart can fix it.
/// - `shutdown()` asks the guest to power off and pulls the plug after
///   `gracePeriod`. `dockerd` needs that time to stop containers cleanly.
@MainActor
final class ThrallEngineSupervisor {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        case stopping
        case backingOff(Duration)
        case stopped
        case failed(String)
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private let makeMachine: () throws -> any ThrallVirtualMachine
    private let sleep: @Sendable (Duration) async throws -> Void
    private let uptime: () -> Duration
    private let gracePeriod: Duration
    private let stableAfter: Duration

    private var machine: (any ThrallVirtualMachine)?
    private var shutdownRequested = false
    private var consecutiveFailures = 0
    private var backoffTask: Task<Void, Error>?
    private var forceStopTask: Task<Void, Never>?
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false

    init(
        gracePeriod: Duration = .seconds(15),
        stableAfter: Duration = .seconds(300),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        uptime: @escaping () -> Duration = { .seconds(ProcessInfo.processInfo.systemUptime) },
        makeMachine: @escaping () throws -> any ThrallVirtualMachine
    ) {
        self.gracePeriod = gracePeriod
        self.stableAfter = stableAfter
        self.sleep = sleep
        self.uptime = uptime
        self.makeMachine = makeMachine
    }

    static func backoff(afterFailures failures: Int) -> Duration {
        .seconds(min(1 << min(max(failures - 1, 0), 6), 60))
    }

    /// Runs until `shutdown()` completes or a configuration error occurs.
    func run() async {
        defer { finish() }
        while !shutdownRequested {
            transition(to: .starting)
            let current: any ThrallVirtualMachine
            do {
                current = try makeMachine()
            } catch {
                transition(to: .failed(String(describing: error)))
                return
            }
            machine = current
            let startedAt = uptime()
            do {
                try await current.start()
                transition(to: .running)
                if shutdownRequested { beginStop(current) }
                _ = await current.waitUntilStopped()
            } catch {
                // A start that throws is a boot failure, not a config error:
                // it gets the same backoff as a crash.
            }
            machine = nil
            forceStopTask?.cancel()
            forceStopTask = nil
            if shutdownRequested { break }

            consecutiveFailures = uptime() - startedAt >= stableAfter ? 1 : consecutiveFailures + 1
            let delay = Self.backoff(afterFailures: consecutiveFailures)
            transition(to: .backingOff(delay))
            let task = Task { [sleep] in try await sleep(delay) }
            backoffTask = task
            _ = await task.result
            backoffTask = nil
        }
        transition(to: .stopped)
    }

    /// Stops the VM gracefully and returns once `run()` has finished.
    func shutdown() async {
        guard !shutdownRequested else { return await waitUntilFinished() }
        shutdownRequested = true
        backoffTask?.cancel()
        if let machine { beginStop(machine) }
        await waitUntilFinished()
    }

    private func beginStop(_ target: any ThrallVirtualMachine) {
        transition(to: .stopping)
        do {
            try target.requestStop()
        } catch {
            Task { try? await target.forceStop() }
            return
        }
        let grace = gracePeriod
        forceStopTask = Task { [sleep, weak self] in
            guard (try? await sleep(grace)) != nil else { return }
            guard let self, self.machine === target else { return }
            try? await target.forceStop()
        }
    }

    private func waitUntilFinished() async {
        if isFinished { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }

    private func finish() {
        isFinished = true
        let waiters = finishedWaiters
        finishedWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func transition(to next: State) {
        state = next
        onStateChange?(next)
    }
}
