import Foundation

/// What the running VM serves on the Mac: the Docker socket and the published
/// ports.
///
/// The Docker socket stays bound across VM restarts, so a client that
/// connects mid-restart is refused cleanly instead of finding no socket at
/// all. Port listeners only exist while a VM runs, because they forward to
/// that boot's guest IP.
@MainActor
final class ThrallEngineServices {
    private let paths: ThrallEnginePaths
    private let log: (String) -> Void
    private var machine: ThrallVZMachine?
    private var guestAddress: String?
    private var dockerSocket: ThrallSocket?
    private var pollTask: Task<Void, Never>?
    private lazy var forwarder = ThrallPortForwarder(
        open: { [unowned self] port in try self.openForward(port) },
        report: log)

    init(paths: ThrallEnginePaths, log: @escaping (String) -> Void) {
        self.paths = paths
        self.log = log
    }

    var dockerSocketPath: String { paths.root.appendingPathComponent("run/docker.sock").path }

    /// Binds `~/.thrall/run/docker.sock` and registers the `thrall` context.
    func start() throws {
        let runDirectory = paths.root.appendingPathComponent("run")
        try FileManager.default.createDirectory(
            at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = try ThrallSocket.unix(path: dockerSocketPath)
        socket.start { [weak self] client in
            Task { @MainActor in
                guard let self else {
                    close(client)
                    return
                }
                self.bridgeDocker(client)
            }
        }
        dockerSocket = socket
        try ThrallDockerContext.register(
            socketPath: dockerSocketPath,
            configDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker"))
    }

    func stop() {
        machineDidStop()
        dockerSocket?.stop()
        dockerSocket = nil
    }

    func machineDidStart(_ machine: ThrallVZMachine) {
        self.machine = machine
        guestAddress = nil
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPublishedPorts()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func machineDidStop() {
        pollTask?.cancel()
        pollTask = nil
        forwarder.stopAll()
        machine = nil
        guestAddress = nil
    }

    // MARK: - Docker socket

    private func bridgeDocker(_ client: Int32) {
        guard let machine else {
            close(client)
            return
        }
        Task {
            do {
                let guest = try await machine.connect(toPort: ThrallVZMachine.dockerPort)
                ThrallSocketPipe.start(client, guest)
            } catch {
                close(client)
            }
        }
    }

    // MARK: - Published ports

    /// ponytail: polls `/containers/json` every 2 s. Port changes reach
    /// localhost within 2 s; switch to the `/events` stream if that is too
    /// slow.
    private func pollPublishedPorts() async {
        guard let machine else { return }
        if guestAddress == nil, let mac = machine.macAddress,
            let leases = try? String(contentsOfFile: ThrallDHCPLeases.path, encoding: .utf8)
        {
            guestAddress = ThrallDHCPLeases.address(forMAC: mac, in: leases)
        }
        guard guestAddress != nil,
            let guest = try? await machine.connect(toPort: ThrallVZMachine.dockerPort)
        else { return }
        let request = ThrallPortForwarder.containersRequest
        let response = await Task.detached { Self.exchange(request, over: guest) }.value
        guard self.machine === machine, let wanted = ThrallPortForwarder.wanted(fromResponse: response) else { return }
        forwarder.reconcile(wanted)
    }

    /// Writes a request, reads to EOF and closes the socket. Blocking, so it
    /// runs off the main actor.
    private nonisolated static func exchange(_ request: Data, over fd: Int32) -> Data {
        defer { close(fd) }
        ThrallSocket.disableSIGPIPE(fd)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let sent = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == request.count else { return Data() }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            response.append(contentsOf: buffer[..<count])
        }
        return response
    }

    private func openForward(_ port: Int) throws -> ThrallSocket {
        guard let host = guestAddress else { throw POSIXError(.EHOSTUNREACH) }
        let listener = try ThrallSocket.tcpLoopback(port: port)
        listener.start { client in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let guest = try? ThrallSocket.connectTCP(host: host, port: port) else {
                    close(client)
                    return
                }
                ThrallSocketPipe.start(client, guest)
            }
        }
        return listener
    }
}
