import Foundation

/// Copies bytes both ways between two connected sockets until both
/// directions end.
///
/// Half-close is preserved: when one side stops sending, the other side's
/// write half is shut down, and the opposite direction keeps flowing. Docker's
/// attach and `exec` streams depend on that. A client closes stdin and still
/// reads the output.
///
/// ponytail: two blocking threads per connection. That is fine for a helper
/// with tens of connections (an events stream, a few log follows, published
/// ports). Move to `DispatchIO` if a workload opens hundreds.
enum ThrallSocketPipe {
    /// Takes ownership of both descriptors and closes them when both
    /// directions have ended, then calls `onClose` once.
    static func start(_ first: Int32, _ second: Int32, onClose: @escaping @Sendable () -> Void = {}) {
        for fd in [first, second] { ThrallSocket.disableSIGPIPE(fd) }
        let remaining = Remaining {
            close(first)
            close(second)
            onClose()
        }
        for (from, to) in [(first, second), (second, first)] {
            let thread = Thread {
                copy(from: from, to: to)
                remaining.oneEnded()
            }
            thread.name = "thrall-engine.pipe"
            thread.start()
        }
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        copying: while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    write(destination, bytes.baseAddress.map { $0 + offset }, count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    break copying
                }
                offset += written
            }
        }
        shutdown(destination, SHUT_WR)
    }

    /// Runs `done` after the second direction ends.
    private final class Remaining: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 2
        private let done: @Sendable () -> Void

        init(done: @escaping @Sendable () -> Void) { self.done = done }

        func oneEnded() {
            let last = lock.withLock {
                count -= 1
                return count == 0
            }
            if last { done() }
        }
    }
}
