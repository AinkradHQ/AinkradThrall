import Foundation
@testable import ThrallFeature

/// A `ThrallByteStream` that replays a canned script of reads and records
/// everything written to it. The reason every parser in `Transport/` is
/// testable with no daemon running.
///
/// `splitting(_:every:)` is the important constructor. Every framing bug this
/// layer can have — a chunk-size line torn in half, a multiplexed frame header
/// straddling two reads, an NDJSON event cut mid-object — is a bug about where
/// a read boundary fell, and it reproduces only at that one offset. Replaying
/// a captured response at every split size turns "works on my socket" into
/// something a test can hold.
actor ScriptedByteStream: ThrallByteStream {
    private var pending: [Data]
    private var didClose = false
    private var sent = Data()
    private(set) var connectCount = 0

    init(reads: [Data]) {
        self.pending = reads
    }

    /// One blob delivered in `size`-byte reads.
    static func splitting(_ data: Data, every size: Int) -> ScriptedByteStream {
        precondition(size > 0)
        var reads: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = min(index + size, data.endIndex)
            reads.append(Data(data[index..<end]))
            index = end
        }
        return ScriptedByteStream(reads: reads)
    }

    func connect() async throws {
        connectCount += 1
    }

    func send(_ bytes: Data) async throws {
        guard !didClose else { throw ThrallTransportError.closed }
        sent.append(bytes)
    }

    func read(timeout: Duration?) async throws -> Data {
        guard !didClose else { throw ThrallTransportError.closed }
        guard !pending.isEmpty else {
            // Script exhausted == the peer closed. Which is exactly what a
            // `Connection: close` response's terminator is.
            didClose = true
            throw ThrallTransportError.closed
        }
        return pending.removeFirst()
    }

    func close() async {
        didClose = true
    }

    var written: Data { sent }
}
