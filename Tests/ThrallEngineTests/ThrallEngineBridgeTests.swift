import Foundation
import Testing

private final class FakeListener: ThrallStoppable {
    var stopped = false
    func stop() { stopped = true }
}

private func socketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
    return (fds[0], fds[1])
}

private func send(_ text: String, to fd: Int32) {
    _ = text.utf8CString.withUnsafeBytes { write(fd, $0.baseAddress, $0.count - 1) }
}

/// Reads until EOF.
private func readAll(_ fd: Int32) -> String {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count <= 0 { break }
        result.append(contentsOf: buffer[..<count])
    }
    return String(decoding: result, as: UTF8.self)
}

@Suite("Thrall engine bridge")
struct ThrallEngineBridgeTests {
    /// The shape `docker attach` relies on: the client closes its sending
    /// half, and the reply still arrives.
    @Test("the pipe copies both ways and keeps a half-closed side readable")
    func pipeHalfClose() throws {
        let (client, clientEnd) = try socketPair()
        let (guestEnd, guest) = try socketPair()
        ThrallSocketPipe.start(clientEnd, guestEnd)

        send("ping", to: client)
        shutdown(client, SHUT_WR)
        #expect(readAll(guest) == "ping")

        send("pong", to: guest)
        close(guest)
        #expect(readAll(client) == "pong")
        close(client)
    }

    @Test("a Unix socket replaces a stale file and is private to the user")
    func unixSocket() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("te-\(UUID().uuidString.prefix(8)).sock").path
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let socket = try ThrallSocket.unix(path: path)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        socket.start { close($0) }
        socket.stop()
    }

    @Test("a path longer than sockaddr_un allows is refused, not truncated")
    func unixPathTooLong() {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        #expect(throws: ThrallSocket.Failure.pathTooLong(path)) { try ThrallSocket.unix(path: path) }
    }

    @MainActor
    @Test("reconcile opens new ports, closes stale ones and reports a conflict once")
    func reconcile() {
        var opened: [Int: FakeListener] = [:]
        var reports: [String] = []
        var taken: Set<Int> = [5432]
        let forwarder = ThrallPortForwarder(
            open: { port in
                if taken.contains(port) { throw ThrallSocket.Failure.system(call: "bind", errno: EADDRINUSE) }
                let listener = FakeListener()
                opened[port] = listener
                return listener
            },
            report: { reports.append($0) })

        forwarder.reconcile([8080, 5432])
        forwarder.reconcile([8080, 5432])
        #expect(Set(forwarder.listeners.keys) == [8080])
        #expect(forwarder.conflicts == [5432])
        #expect(reports.count == 1)
        #expect(reports.first?.contains("localhost:5432") == true)

        taken = []
        forwarder.reconcile([5432])
        #expect(Set(forwarder.listeners.keys) == [5432])
        #expect(opened[8080]?.stopped == true)
        #expect(forwarder.conflicts.isEmpty)

        forwarder.stopAll()
        #expect(forwarder.listeners.isEmpty)
        #expect(opened[5432]?.stopped == true)
    }

    @Test("published TCP ports are read from a /containers/json response")
    func wantedFromResponse() {
        let body = """
            [{"Id":"a","Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},\
            {"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},\
            {"PrivatePort":5432,"Type":"tcp"},\
            {"IP":"0.0.0.0","PrivatePort":53,"PublicPort":5353,"Type":"udp"}]},\
            {"Id":"b","Ports":[]}]
            """
        let response = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
        #expect(ThrallPortForwarder.wanted(fromResponse: response) == [8080])
        let error = Data("HTTP/1.0 500 Internal Server Error\r\n\r\n{\"message\":\"x\"}".utf8)
        #expect(ThrallPortForwarder.wanted(fromResponse: error) == nil)
        #expect(ThrallPortForwarder.wanted(fromResponse: Data()) == nil)
    }

    @Test("the guest IP is found by MAC, matching the lease file's unpadded octets")
    func dhcpLease() {
        let leases = """
            {
            \tname=other
            \tip_address=192.168.64.2
            \thw_address=1,de:ad:be:ef:0:1
            \tlease=0x67
            }
            {
            \tname=thrall
            \tip_address=192.168.64.3
            \thw_address=1,2e:1:3f:a:b:c
            \tlease=0x68
            }
            """
        #expect(ThrallDHCPLeases.address(forMAC: "2e:01:3f:0a:0b:0c", in: leases) == "192.168.64.3")
        #expect(ThrallDHCPLeases.address(forMAC: "de:ad:be:ef:00:01", in: leases) == "192.168.64.2")
        #expect(ThrallDHCPLeases.address(forMAC: "aa:bb:cc:dd:ee:ff", in: leases) == nil)
    }

    @Test("the context is written where the CLI looks, and config.json is untouched")
    func dockerContext() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("docker-\(UUID().uuidString)")
        try ThrallDockerContext.register(socketPath: "/Users/me/.thrall/run/docker.sock", configDirectory: config)
        let directories = try FileManager.default.contentsOfDirectory(
            atPath: config.appendingPathComponent("contexts/meta").path)
        // sha256("thrall"): the store names each context's directory that way.
        #expect(directories == ["0c74d684c7bf7876e23301c2008a3e464bfcf55d828e78c43c8e0c40aba42514"])
        let written = config.appendingPathComponent("contexts/meta/\(directories[0])/meta.json")
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: written)) as? [String: Any])
        #expect(root["Name"] as? String == "thrall")
        let endpoints = root["Endpoints"] as? [String: [String: Any]]
        #expect(endpoints?["docker"]?["Host"] as? String == "unix:///Users/me/.thrall/run/docker.sock")
        #expect(!FileManager.default.fileExists(atPath: config.appendingPathComponent("config.json").path))
    }

    @Test("the home share goes on the kernel command line, unless its path has whitespace")
    func sharedHome() {
        #expect(ThrallVMSpec.sharedHome("/Users/me") == "/Users/me")
        #expect(ThrallVMSpec.sharedHome("/Users/my name") == nil)
        #expect(ThrallVMSpec.kernelCommandLine(sharedHome: "/Users/me").hasSuffix(" thrall.home=/Users/me"))
        #expect(!ThrallVMSpec.kernelCommandLine(sharedHome: nil).contains("thrall.home"))
    }
}
