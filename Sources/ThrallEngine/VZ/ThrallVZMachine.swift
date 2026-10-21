import Foundation
import Virtualization

/// `ThrallVirtualMachine` on `Virtualization.framework`.
///
/// The VM is created without a queue, so it lives on the main queue: every
/// call and every delegate callback runs there, which is what makes
/// `@MainActor` here a fact rather than a promise.
@MainActor
final class ThrallVZMachine: NSObject, ThrallVirtualMachine {
    private let machine: VZVirtualMachine
    private let console: FileHandle
    /// The guest's MAC, used to find its IP in the DHCP lease file.
    let macAddress: String?
    private var stopReason: ThrallVMStopReason?
    private var waiters: [CheckedContinuation<ThrallVMStopReason, Never>] = []

    init(configuration: VZVirtualMachineConfiguration, console: FileHandle) {
        machine = VZVirtualMachine(configuration: configuration)
        self.console = console
        macAddress = configuration.networkDevices.first?.macAddress.string
        super.init()
        machine.delegate = self
    }

    func start() async throws {
        try await machine.start()
    }

    /// Asks the guest to power off over vsock port 2376.
    ///
    /// Not `VZVirtualMachine.requestStop()`: that presses a device-tree
    /// `gpio-keys` power button, and Alpine's kernels carry no driver for it,
    /// so the guest never sees it. A connect that fails (the guest is still
    /// booting) is left to the supervisor's force-stop after the grace period.
    func requestStop() throws {
        guard let socket = machine.socketDevices.first as? VZVirtioSocketDevice else {
            return try machine.requestStop()
        }
        socket.connect(toPort: Self.powerPort) { result in
            // The guest acts on the connection itself; no data is sent.
            if case .success(let connection) = result { connection.close() }
        }
    }

    /// Matches `thrall-power` in the guest image.
    static let powerPort: UInt32 = 2376
    /// Matches `thrall-socket` in the guest image.
    static let dockerPort: UInt32 = 2375

    /// Connects to a vsock port in the guest and returns a socket descriptor
    /// the caller owns.
    ///
    /// The descriptor is a `dup` of the connection's own, and the connection
    /// object is closed at once: the socket stays open until the caller
    /// closes its copy, and the caller never has to keep a Virtualization
    /// object alive off the main actor.
    func connect(toPort port: UInt32) async throws -> Int32 {
        guard let socket = machine.socketDevices.first as? VZVirtioSocketDevice else {
            throw ThrallEngineConfigError.invalidConfiguration("the VM has no vsock device")
        }
        let connection = try await socket.connect(toPort: port)
        let descriptor = dup(connection.fileDescriptor)
        connection.close()
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        return descriptor
    }

    func forceStop() async throws {
        // `stop()` does not call the delegate, so the stop is recorded here.
        try await machine.stop()
        finish(.forced)
    }

    func waitUntilStopped() async -> ThrallVMStopReason {
        if let stopReason { return stopReason }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finish(_ reason: ThrallVMStopReason) {
        guard stopReason == nil else { return }
        stopReason = reason
        try? console.close()
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: reason) }
    }
}

extension ThrallVZMachine: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(.guest) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(.error(message)) }
    }
}
