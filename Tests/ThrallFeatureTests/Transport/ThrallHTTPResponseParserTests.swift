import Foundation
import Testing
@testable import ThrallFeature

/// The parser is the load-bearing piece of the transport: every other layer
/// reads what it emits, so a framing mistake here surfaces three layers up as
/// "the container list is corrupt". None of these tests needs a daemon.
@Suite("ThrallHTTPResponseParser")
struct ThrallHTTPResponseParserTests {
    /// Feeds a whole response and returns every event, treating exhaustion as
    /// the peer closing — which is what `Connection: close` means.
    private func parseAll(_ data: Data,
                          splitEvery: Int? = nil,
                          limits: ThrallHTTPResponseParser.Limits = .default) throws
        -> [ThrallHTTPResponseParser.Output] {
        var parser = ThrallHTTPResponseParser(limits: limits)
        var events: [ThrallHTTPResponseParser.Output] = []
        if let splitEvery {
            var index = data.startIndex
            while index < data.endIndex {
                let end = min(index + splitEvery, data.endIndex)
                events += try parser.feed(Data(data[index..<end]))
                index = end
            }
        } else {
            events += try parser.feed(data)
        }
        events += try parser.finish()
        return events
    }

    private func head(of events: [ThrallHTTPResponseParser.Output]) -> ThrallHTTPResponseHead? {
        for event in events { if case .head(let value) = event { return value } }
        return nil
    }

    private func body(of events: [ThrallHTTPResponseParser.Output]) -> Data {
        events.reduce(into: Data()) { accumulated, event in
            if case .body(let chunk) = event { accumulated.append(chunk) }
        }
    }

    // MARK: - The two framings the engine actually uses

    @Test("a Content-Length response yields head, body and end")
    func contentLength() throws {
        let events = try parseAll(RawResponses.versionContentLength)
        let head = try #require(head(of: events))
        #expect(head.statusCode == 200)
        #expect(head.reasonPhrase == "OK")
        #expect(head.isSuccess)
        #expect(head.contentType == "application/json")
        #expect(head.headers.first("Api-Version") == "1.54")
        #expect(body(of: events) == RawResponses.versionBody)
        #expect(events.last == .end)
    }

    /// `/containers/json` is chunked, so a parser that handles content-length
    /// only cannot read Thrall's primary endpoint at all.
    @Test("a chunked response is dechunked across two chunks")
    func chunked() throws {
        let events = try parseAll(RawResponses.containersChunked)
        let head = try #require(head(of: events))
        #expect(head.headers.first("Transfer-Encoding") == "chunked")
        #expect(head.headers.first("Content-Length") == nil)
        #expect(body(of: events) == RawResponses.containersBody)
        #expect(events.last == .end)
        // Proof it was really two chunks and not one accidental blob.
        #expect(events.filter { if case .body = $0 { return true } else { return false } }.count == 2)
    }

    @Test("chunk extensions are ignored and trailers are reported")
    func chunkExtensionsAndTrailers() throws {
        var data = RawResponses.bytes(RawResponses.chunkedHead)
        data += RawResponses.chunk("hello", extensions: ";name=\"value\"")
        data += RawResponses.bytes("0\r\nX-Digest: sha256:abc\r\n\r\n")
        let events = try parseAll(data)
        #expect(body(of: events) == Data("hello".utf8))
        var reported: ThrallHTTPHeaders?
        for event in events { if case .trailers(let value) = event { reported = value } }
        #expect(try #require(reported).first("x-digest") == "sha256:abc")
        #expect(events.last == .end)
    }

    /// The latency decision, made observable: body bytes are emitted the
    /// moment they land, not when their chunk completes. Without this a
    /// `follow` log stream would arrive in 16 KB steps.
    @Test("body bytes are emitted mid-chunk, before the chunk completes")
    func emitsMidChunk() throws {
        var parser = ThrallHTTPResponseParser()
        _ = try parser.feed(RawResponses.bytes(RawResponses.chunkedHead))
        // A chunk that claims 10 bytes, of which only 4 have arrived.
        let events = try parser.feed(RawResponses.bytes("a\r\nfour"))
        #expect(events == [.body(Data("four".utf8))])
        #expect(!parser.isFinished)
    }

    /// The boundary fuzzer. Every framing bug in this layer is a bug about
    /// where a read boundary fell, and it reproduces at exactly one offset.
    @Test("splitting the response at every boundary yields identical output",
          arguments: [1, 2, 3, 7, 13, 64, 200, 4096])
    func byteBoundariesDoNotMatter(splitEvery: Int) throws {
        for fixture in [RawResponses.containersChunked,
                        RawResponses.versionContentLength,
                        RawResponses.redirectEmptyBody] {
            let whole = try parseAll(fixture)
            let split = try parseAll(fixture, splitEvery: splitEvery)
            #expect(head(of: split) == head(of: whole))
            #expect(body(of: split) == body(of: whole))
            #expect(split.last == whole.last)
        }
    }

    // MARK: - Body-less and open-ended shapes

    /// The engine's real answer to a mis-typed path. It has to complete, not
    /// sit waiting for a body it will never send.
    @Test("Content-Length: 0 completes immediately")
    func zeroLengthBody() throws {
        let events = try parseAll(RawResponses.redirectEmptyBody)
        let head = try #require(head(of: events))
        #expect(head.statusCode == 301)
        #expect(head.headers.first("Location") == "/v1.51/containers/logs")
        #expect(body(of: events).isEmpty)
        #expect(events == [.head(head), .end])
    }

    @Test("204 carries no body")
    func noContent() throws {
        let events = try parseAll(RawResponses.bytes("HTTP/1.1 204 No Content\r\n\r\n"))
        #expect(events.count == 2)
        #expect(events.last == .end)
    }

    @Test("a body with no declared framing runs to end-of-connection")
    func untilClose() throws {
        let data = RawResponses.bytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nopaque")
        let events = try parseAll(data)
        #expect(body(of: events) == Data("opaque".utf8))
        #expect(events.last == .end)
    }

    @Test("an empty reason phrase parses")
    func emptyReasonPhrase() throws {
        let events = try parseAll(RawResponses.bytes("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n"))
        let head = try #require(head(of: events))
        #expect(head.statusCode == 200)
        #expect(head.reasonPhrase.isEmpty)
    }

    /// Field names are case-insensitive per RFC 9110, and the log path's whole
    /// framing decision is one `Content-Type` lookup.
    @Test("header lookup ignores case")
    func headerCaseInsensitivity() throws {
        let data = RawResponses.bytes(
            "HTTP/1.1 200 OK\r\ncontent-type: application/JSON; charset=utf-8\r\n"
                + "CONTENT-LENGTH: 0\r\n\r\n")
        let head = try #require(head(of: try parseAll(data)))
        #expect(head.contentType == "application/json")
    }

    // MARK: - The upgrade

    /// The bug this test exists to prevent: the engine's `101` and the
    /// container's first output arrive in the same read, so bytes past the
    /// header terminator are payload. Dropping them loses the first line of a
    /// prompt, intermittently.
    @Test("a 101 reports the bytes already buffered past the header terminator")
    func upgradeKeepsResidual() throws {
        let data = RawResponses.bytes(
            "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\n"
                + "Connection: Upgrade\r\nUpgrade: tcp\r\n\r\nroot@abc:/# ")
        var parser = ThrallHTTPResponseParser()
        let events = try parser.feed(data)
        #expect(events.count == 2)
        #expect(events.last == .upgraded(residual: Data("root@abc:/# ".utf8)))
        #expect(parser.isFinished)
        // And it refuses to keep parsing: those bytes belong to the container
        // now, not to HTTP.
        #expect(throws: ThrallTransportError.self) { try parser.feed(Data("more".utf8)) }
    }

    @Test("a 101 with nothing buffered reports an empty residual")
    func upgradeWithoutResidual() throws {
        var parser = ThrallHTTPResponseParser()
        let events = try parser.feed(RawResponses.bytes("HTTP/1.1 101 UPGRADED\r\nUpgrade: tcp\r\n\r\n"))
        #expect(events.last == .upgraded(residual: Data()))
    }

    // MARK: - Framing is refused, never guessed

    @Test("Transfer-Encoding alongside Content-Length is refused")
    func smugglingShape() throws {
        let data = RawResponses.bytes(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n")
        #expect(throws: ThrallTransportError.self) { try parseAll(data) }
    }

    @Test("a repeated, disagreeing Content-Length is refused")
    func repeatedContentLength() throws {
        let data = RawResponses.bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 9\r\n\r\nhello")
        #expect(throws: ThrallTransportError.self) { try parseAll(data) }
    }

    @Test("a repeated, agreeing Content-Length is accepted")
    func repeatedAgreeingContentLength() throws {
        let data = RawResponses.bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello")
        #expect(body(of: try parseAll(data)) == Data("hello".utf8))
    }

    @Test("a non-identity transfer coding is refused rather than handed on compressed",
          arguments: ["gzip, chunked", "gzip"])
    func compressedTransferEncoding(encoding: String) throws {
        let data = RawResponses.bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: \(encoding)\r\n\r\n")
        #expect(throws: ThrallTransportError.unsupportedFraming("Transfer-Encoding: \(encoding)")) {
            try parseAll(data)
        }
    }

    @Test("malformed framing is rejected", arguments: [
        // Not HTTP at all — what a pooled connection reused after a hijack
        // would deliver.
        "root@abc:/# echo hi\r\n\r\n",
        // Status code that is not three digits.
        "HTTP/1.1 20 OK\r\n\r\n",
        // obs-folded header: where a value ends becomes ambiguous.
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\tcharset=utf-8\r\nContent-Length: 0\r\n\r\n",
        // Whitespace before the colon.
        "HTTP/1.1 200 OK\r\nContent-Length : 0\r\n\r\n",
        // A header line with no colon.
        "HTTP/1.1 200 OK\r\nContent-Length\r\n\r\n",
        // A signed length.
        "HTTP/1.1 200 OK\r\nContent-Length: +5\r\n\r\nhello",
        // A chunk size that is not hex.
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n",
        // An unexpected informational response: we send no `Expect`.
        "HTTP/1.1 100 Continue\r\n\r\n",
    ])
    func malformedResponses(text: String) throws {
        #expect(throws: ThrallTransportError.self) { try parseAll(RawResponses.bytes(text)) }
    }

    /// The desync detector for chunked: a chunk whose data is not followed by
    /// CRLF means the size we read was not the size on the wire, and every
    /// byte after it would be misattributed.
    @Test("a chunk not followed by CRLF is a desync, not a hiccup")
    func chunkTerminatorMissing() throws {
        var data = RawResponses.bytes(RawResponses.chunkedHead)
        data += RawResponses.bytes("5\r\nhelloXX0\r\n\r\n")
        #expect(throws: ThrallTransportError.self) { try parseAll(data) }
    }

    // MARK: - Caps

    @Test("a chunk size over the cap is refused before it is allocated")
    func chunkSizeCap() throws {
        var data = RawResponses.bytes(RawResponses.chunkedHead)
        data += RawResponses.bytes("ffffffff\r\n")
        let limits = ThrallHTTPResponseParser.Limits(maximumChunkSize: 1024)
        #expect(throws: ThrallTransportError.self) { try parseAll(data, limits: limits) }
    }

    @Test("a header block over the cap is refused")
    func headerBlockCap() throws {
        var text = "HTTP/1.1 200 OK\r\n"
        for index in 0..<200 { text += "X-Pad-\(index): \(String(repeating: "p", count: 200))\r\n" }
        text += "\r\n"
        let limits = ThrallHTTPResponseParser.Limits(maximumHeaderBlock: 4096)
        #expect(throws: ThrallTransportError.self) { try parseAll(RawResponses.bytes(text), limits: limits) }
    }

    // MARK: - End of connection

    /// An engine restart drops the socket without a byte. It must read as
    /// `.closed` so the caller reconnects, not as corruption.
    @Test("a connection that closes before saying anything reports closed")
    func closedBeforeStatusLine() throws {
        var parser = ThrallHTTPResponseParser()
        #expect(throws: ThrallTransportError.closed) { try parser.finish() }
    }

    @Test("a connection that closes mid-response is a truncation")
    func truncatedMidBody() throws {
        var parser = ThrallHTTPResponseParser()
        _ = try parser.feed(RawResponses.bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nfour"))
        #expect(throws: ThrallTransportError.self) { try parser.finish() }
    }

    @Test("a second message on the same socket is refused — nothing pipelines here")
    func noPipelining() throws {
        var parser = ThrallHTTPResponseParser()
        _ = try parser.feed(RawResponses.versionContentLength)
        #expect(parser.isFinished)
        #expect(throws: ThrallTransportError.self) {
            try parser.feed(RawResponses.bytes("HTTP/1.1 200 OK\r\n\r\n"))
        }
    }
}
