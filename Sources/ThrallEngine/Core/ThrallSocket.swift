import Foundation

/// A listening socket that hands each accepted connection to a callback.
///
/// Accepting runs on a dispatch source, not a blocked thread, because a
/// thread parked in `accept()` cannot be woken reliably on macOS by closing
/// the descriptor. Cancelling the source can.
final class ThrallSocket: @unchecked Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case system(call: String, errno: Int32)
        case pathTooLong(String)

        var description: String {
            switch self {
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            case .pathTooLong(let path): return "socket path is too long: \(path)"
            }
        }

        var isAddressInUse: Bool { self == .system(call: "bind", errno: EADDRINUSE) }
    }

    private let descriptor: Int32
    private let unixPath: String?
    private let queue = DispatchQueue(label: "com.ainkrad.thrall.engine.listener")
    private var source: DispatchSourceRead?

    private init(descriptor: Int32, unixPath: String?) {
        self.descriptor = descriptor
        self.unixPath = unixPath
    }

    /// Listens on a Unix socket readable by the current user only. A stale
    /// socket file left by a crash is removed first.
    static func unix(path: String) throws -> ThrallSocket {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        unlink(path)
        let fd = try make(AF_UNIX)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw closing(fd, "bind") }
        chmod(path, 0o600)
        return try listening(fd, unixPath: path)
    }

    /// Listens on `127.0.0.1:port`. Loopback only, so a published database
    /// port is not exposed to the local network by default.
    static func tcpLoopback(port: Int) throws -> ThrallSocket {
        let fd = try make(AF_INET)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw closing(fd, "bind") }
        return try listening(fd, unixPath: nil)
    }

    /// Opens a TCP connection, blocking until it connects or fails.
    static func connectTCP(host: String, port: Int) throws -> Int32 {
        let fd = try make(AF_INET)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw closing(fd, "connect") }
        return fd
    }

    /// Starts accepting. Each accepted descriptor is a blocking socket the
    /// callback owns.
    func start(onAccept: @escaping @Sendable (Int32) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let fd = descriptor
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                onAccept(client)
            }
        }
        source.setCancelHandler { [unixPath] in
            close(fd)
            if let unixPath { unlink(unixPath) }
        }
        self.source = source
        source.resume()
    }

    /// Stops accepting and closes the socket. Open connections are not
    /// affected.
    func stop() {
        source?.cancel()
        source = nil
    }

    static func disableSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func make(_ family: Int32) throws -> Int32 {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system(call: "socket", errno: errno) }
        return fd
    }

    private static func listening(_ fd: Int32, unixPath: String?) throws -> ThrallSocket {
        guard listen(fd, 128) == 0 else { throw closing(fd, "listen") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return ThrallSocket(descriptor: fd, unixPath: unixPath)
    }

    private static func closing(_ fd: Int32, _ call: String) -> Failure {
        let code = errno
        close(fd)
        return .system(call: call, errno: code)
    }
}
