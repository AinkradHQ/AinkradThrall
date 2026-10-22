import Foundation
import Testing

/// A VM that does nothing until a test stops it.
@MainActor
private final class FakeMachine: ThrallVirtualMachine {
    var startError: (any Error)?
    var stopRequests = 0
    var forceStops = 0
    /// When true, `requestStop()` stops the VM at once, like a guest that
    /// handles the power button.
    var obeysStopRequest = true
    private var reason: ThrallVMStopReason?
    private var waiters: [CheckedContinuation<ThrallVMStopReason, Never>] = []

    func start() async throws {
        if let startError { throw startError }
    }

    func requestStop() throws {
        stopRequests += 1
        if obeysStopRequest { stop(.guest) }
    }

    func forceStop() async throws {
        forceStops += 1
        stop(.forced)
    }

    func waitUntilStopped() async -> ThrallVMStopReason {
        if let reason { return reason }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func stop(_ reason: ThrallVMStopReason) {
        guard self.reason == nil else { return }
        self.reason = reason
        for waiter in waiters { waiter.resume(returning: reason) }
        waiters = []
    }
}

/// Records each sleep and returns at once, unless the sleep is the one a
/// test wants to hold open.
private final class FakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var sleeps: [Duration] { lock.withLock { recorded } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { recorded.append(duration) }
        try Task.checkCancellation()
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
}

@MainActor
@Suite("ThrallEngineSupervisor")
struct ThrallEngineSupervisorTests {
    @Test("backoff doubles from 1 s and caps at 60 s")
    func backoffCurve() {
        let delays = (1...8).map { ThrallEngineSupervisor.backoff(afterFailures: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
    }

    @Test("a crashed VM is restarted, with growing backoff")
    func restartsAfterCrash() async {
        var machines: [FakeMachine] = []
        let sleeper = FakeSleeper()
        let supervisor = ThrallEngineSupervisor(sleep: sleeper.sleep, uptime: { .zero }) {
            let machine = FakeMachine()
            machines.append(machine)
            return machine
        }
        let run = Task { await supervisor.run() }

        for crash in 1...3 {
            await eventually { machines.count == crash && supervisor.state == .running }
            machines[crash - 1].stop(.error("crashed"))
        }
        await eventually { machines.count == 4 && supervisor.state == .running }
        #expect(sleeper.sleeps == [.seconds(1), .seconds(2), .seconds(4)])

        await supervisor.shutdown()
        await run.value
        #expect(supervisor.state == .stopped)
    }

    @Test("a VM that ran past stableAfter resets the backoff")
    func stableRunResetsBackoff() async {
        var machines: [FakeMachine] = []
        var clock = Duration.zero
        let sleeper = FakeSleeper()
        let supervisor = ThrallEngineSupervisor(
            stableAfter: .seconds(300), sleep: sleeper.sleep, uptime: { clock }
        ) {
            let machine = FakeMachine()
            machines.append(machine)
            return machine
        }
        let run = Task { await supervisor.run() }

        await eventually { machines.count == 1 && supervisor.state == .running }
        machines[0].stop(.error("crashed"))
        await eventually { machines.count == 2 && supervisor.state == .running }
        clock = .seconds(301)
        machines[1].stop(.error("crashed again, a day later"))
        await eventually { machines.count == 3 && supervisor.state == .running }
        #expect(sleeper.sleeps == [.seconds(1), .seconds(1)])

        await supervisor.shutdown()
        await run.value
    }

    @Test("a configuration error ends run() without a restart")
    func configErrorFails() async {
        var attempts = 0
        let supervisor = ThrallEngineSupervisor(sleep: FakeSleeper().sleep) {
            attempts += 1
            throw ThrallEngineConfigError.missingImageFile("/x/Image")
        }
        await supervisor.run()
        #expect(attempts == 1)
        guard case .failed(let reason) = supervisor.state else {
            Issue.record("expected failed, got \(supervisor.state)")
            return
        }
        #expect(reason.contains("/x/Image"))
    }

    @Test("a start that throws is retried like a crash")
    func startFailureRetries() async {
        var machines: [FakeMachine] = []
        let sleeper = FakeSleeper()
        let supervisor = ThrallEngineSupervisor(sleep: sleeper.sleep, uptime: { .zero }) {
            let machine = FakeMachine()
            if machines.isEmpty { machine.startError = CocoaError(.fileReadUnknown) }
            machines.append(machine)
            return machine
        }
        let run = Task { await supervisor.run() }
        await eventually { machines.count == 2 && supervisor.state == .running }
        #expect(sleeper.sleeps == [.seconds(1)])
        await supervisor.shutdown()
        await run.value
    }

    @Test("shutdown asks the guest first and does not force a VM that obeys")
    func gracefulShutdown() async {
        let machine = FakeMachine()
        let supervisor = ThrallEngineSupervisor(sleep: FakeSleeper().sleep) { machine }
        let run = Task { await supervisor.run() }
        await eventually { supervisor.state == .running }

        await supervisor.shutdown()
        await run.value
        #expect(machine.stopRequests == 1)
        #expect(machine.forceStops == 0)
        #expect(supervisor.state == .stopped)
    }

    @Test("shutdown forces a guest that ignores the stop request after the grace period")
    func forcedShutdown() async {
        let machine = FakeMachine()
        machine.obeysStopRequest = false
        let sleeper = FakeSleeper()
        let supervisor = ThrallEngineSupervisor(gracePeriod: .seconds(15), sleep: sleeper.sleep) { machine }
        let run = Task { await supervisor.run() }
        await eventually { supervisor.state == .running }

        await supervisor.shutdown()
        await run.value
        #expect(machine.forceStops == 1)
        #expect(sleeper.sleeps == [.seconds(15)])
    }

    @Test("shutdown during backoff stops without starting another VM")
    func shutdownDuringBackoff() async {
        var machines: [FakeMachine] = []
        let supervisor = ThrallEngineSupervisor(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }) {
            let machine = FakeMachine()
            machines.append(machine)
            return machine
        }
        let run = Task { await supervisor.run() }
        await eventually { supervisor.state == .running }
        machines[0].stop(.error("crashed"))
        await eventually { supervisor.state == .backingOff(.seconds(1)) }

        await supervisor.shutdown()
        await run.value
        #expect(machines.count == 1)
        #expect(supervisor.state == .stopped)
    }
}
