import Foundation
import Testing
@testable import ThrallFeature

/// `/events` is the only reason Thrall can report a transition rather than a
/// snapshot, and it arrives as NDJSON over a chunked body. The splitter's job
/// is to stop caring where chunk boundaries fell.
@Suite("ThrallNDJSONSplitter")
struct ThrallNDJSONSplitterTests {
    private func text(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("two records in one read come out as two lines")
    func twoRecordsOneRead() throws {
        var splitter = ThrallNDJSONSplitter()
        let lines = try splitter.feed(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        #expect(text(lines) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(splitter.finish().isEmpty)
    }

    @Test("a record split across reads is held until its newline arrives")
    func recordSplitAcrossReads() throws {
        var splitter = ThrallNDJSONSplitter()
        #expect(try splitter.feed(Data("{\"a\":".utf8)).isEmpty)
        #expect(text(try splitter.feed(Data("1}\n".utf8))) == ["{\"a\":1}"])
    }

    @Test("CRLF-terminated records lose the carriage return")
    func crlfTermination() throws {
        var splitter = ThrallNDJSONSplitter()
        #expect(text(try splitter.feed(Data("{\"a\":1}\r\n".utf8))) == ["{\"a\":1}"])
    }

    /// A long-poll may send a bare newline to keep the socket warm. It is not
    /// a document, and handing it to `JSONDecoder` would report a parse error
    /// for a perfectly healthy stream.
    @Test("blank lines are dropped rather than reported as records")
    func blankLinesDropped() throws {
        var splitter = ThrallNDJSONSplitter()
        #expect(text(try splitter.feed(Data("\n\n{\"a\":1}\n\n".utf8))) == ["{\"a\":1}"])
    }

    /// The measured case: an event carrying a container's full label set runs
    /// well past a kilobyte, so one chunk is never one event. Split at every
    /// awkward size to prove it.
    @Test("a realistic multi-kilobyte event survives any read boundary",
          arguments: [1, 7, 64, 500, 1024, 4096])
    func realisticEventsAcrossBoundaries(splitEvery: Int) throws {
        let records = [
            RawResponses.eventLine(action: "die", container: "f4b70cccfc26"),
            RawResponses.eventLine(action: "start", container: "aec9af6e5312"),
            RawResponses.eventLine(action: "exec_die", container: "f4b70cccfc26"),
        ]
        let stream = Data(records.map { $0 + "\n" }.joined().utf8)
        // A single event must exceed a kilobyte for the fixture to be
        // representative — measured median here is 1371 bytes.
        #expect(records.allSatisfy { $0.utf8.count > 1024 })

        var splitter = ThrallNDJSONSplitter()
        var lines: [Data] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = min(index + splitEvery, stream.endIndex)
            lines += try splitter.feed(Data(stream[index..<end]))
            index = end
        }
        #expect(splitter.finish().isEmpty)
        #expect(text(lines) == records)
        // And each line is independently decodable — the actual contract.
        for line in lines {
            _ = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        }
    }

    /// A peer that never sends a newline would otherwise grow the carry buffer
    /// for the whole session, and `/events` stays open for the whole session.
    @Test("an unterminated record over the cap is refused")
    func carryBufferCap() throws {
        var splitter = ThrallNDJSONSplitter(maximumLineLength: 64)
        #expect(throws: ThrallTransportError.self) {
            try splitter.feed(Data(String(repeating: "x", count: 100).utf8))
        }
    }

    /// Returned rather than flushed as a line: a record cut mid-object is
    /// invalid JSON, and a caller that is handed it as a line will try.
    @Test("a partial record at end-of-stream is reported by finish")
    func partialRecordAtEnd() throws {
        var splitter = ThrallNDJSONSplitter()
        _ = try splitter.feed(Data("{\"a\":1}\n{\"b\":".utf8))
        #expect(String(decoding: splitter.finish(), as: UTF8.self) == "{\"b\":")
        #expect(splitter.finish().isEmpty, "finish must not hand the same remainder out twice")
    }
}
