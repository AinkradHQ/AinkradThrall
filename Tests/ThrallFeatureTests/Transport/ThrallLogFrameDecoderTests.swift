import Foundation
import Testing
@testable import ThrallFeature

/// Log framing is the one place in this transport where getting it wrong does
/// not fail — it renders garbage. These tests pin both the selection rule and
/// the desync detection that makes a wrong selection loud.
@Suite("ThrallLogFrameDecoder")
struct ThrallLogFrameDecoderTests {
    @Test("framing comes from the Content-Type and nothing else", arguments: [
        ("application/vnd.docker.multiplexed-stream", ThrallLogFrameDecoder.Framing.multiplexed),
        ("application/vnd.docker.raw-stream", ThrallLogFrameDecoder.Framing.raw),
    ])
    func framingSelection(contentType: String, expected: ThrallLogFrameDecoder.Framing) {
        #expect(ThrallLogFrameDecoder.framing(forContentType: contentType) == expected)
    }

    /// Nil is a hard stop at the call site. There is no defensible default:
    /// guessing multiplexed on a raw stream renders garbage, and guessing raw
    /// on a multiplexed one prints the frame headers.
    @Test("an unrecognised or absent Content-Type selects nothing",
          arguments: [nil, "application/json", "text/plain", "application/vnd.docker.multiplexed"])
    func unknownFramingIsRefused(contentType: String?) {
        #expect(ThrallLogFrameDecoder.framing(forContentType: contentType) == nil)
    }

    @Test("a multiplexed frame decodes to its stream and payload")
    func decodesOneFrame() throws {
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed)
        let line = Data("  \u{2192} '/usr/local/bin/php' 'artisan' subscriptions:expire\n".utf8)
        let frames = try decoder.feed(RawResponses.logFrame(stream: 1, payload: line))
        #expect(frames == [ThrallLogFrame(stream: .stdout, payload: line)])
        #expect(decoder.finish().isEmpty)
    }

    @Test("stderr and stdout are kept apart")
    func separatesStreams() throws {
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed)
        var data = RawResponses.logFrame(stream: 1, payload: Data("out\n".utf8))
        data += RawResponses.logFrame(stream: 2, payload: Data("err\n".utf8))
        let frames = try decoder.feed(data)
        #expect(frames.map(\.stream) == [.stdout, .stderr])
        #expect(frames.map(\.payload) == [Data("out\n".utf8), Data("err\n".utf8)])
    }

    /// The dechunker above emits on chunk arrival and a frame has no reason to
    /// align to a chunk, so a header straddling two reads is the normal case,
    /// not an edge one.
    @Test("a frame split across reads reassembles", arguments: [1, 2, 3, 5, 8, 9, 17])
    func reassemblesAcrossReads(splitEvery: Int) throws {
        var data = RawResponses.logFrame(stream: 1, payload: Data("first line\n".utf8))
        data += RawResponses.logFrame(stream: 2, payload: Data("second\n".utf8))
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed)
        var frames: [ThrallLogFrame] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = min(index + splitEvery, data.endIndex)
            frames += try decoder.feed(Data(data[index..<end]))
            index = end
        }
        #expect(frames.map(\.payload) == [Data("first line\n".utf8), Data("second\n".utf8)])
        #expect(decoder.finish().isEmpty)
    }

    @Test("a raw stream is passed through as stdout, unframed")
    func rawPassthrough() throws {
        var decoder = ThrallLogFrameDecoder(framing: .raw)
        let bytes = Data("root@abc:/# ls\r\n".utf8)
        #expect(try decoder.feed(bytes) == [ThrallLogFrame(stream: .stdout, payload: bytes)])
    }

    /// The hazard, made loud. A TTY container's output demultiplexed as if it
    /// were framed used to render garbage; now it throws inside one frame.
    @Test("demultiplexing a raw stream throws instead of rendering garbage")
    func desyncIsDetected() throws {
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed)
        // Real shell output. Byte 0 is 'r' (114), which is no stream at all.
        #expect(throws: ThrallTransportError.self) {
            try decoder.feed(Data("root@abc:/# ls -la /var/log\n".utf8))
        }
    }

    @Test("non-zero padding in a frame header is a desync")
    func nonZeroPaddingIsDesync() throws {
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed)
        var frame = Data([1, 0, 9, 0, 0, 0, 0, 4])
        frame.append(Data("abcd".utf8))
        #expect(throws: ThrallTransportError.self) { try decoder.feed(frame) }
    }

    @Test("a frame length over the cap is refused before it is allocated")
    func frameLengthCap() throws {
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed, maximumFrameLength: 1024)
        let header = Data([1, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: ThrallTransportError.self) { try decoder.feed(header) }
    }

    @Test("a zero-length frame emits nothing and does not stall the stream")
    func zeroLengthFrame() throws {
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed)
        var data = RawResponses.logFrame(stream: 1, payload: Data())
        data += RawResponses.logFrame(stream: 1, payload: Data("after\n".utf8))
        #expect(try decoder.feed(data).map(\.payload) == [Data("after\n".utf8)])
    }

    /// A partial frame is returned, never emitted: its declared length is
    /// unknown, so guessing would put a fragment of the next header on screen.
    @Test("a truncated frame is reported by finish, not emitted")
    func truncatedFrame() throws {
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed)
        let full = RawResponses.logFrame(stream: 1, payload: Data("complete\n".utf8))
        #expect(try decoder.feed(Data(full[0..<(full.count - 3)])).isEmpty)
        #expect(decoder.finish().count == full.count - 3)
    }

    /// Both layers at once, which is the real arrangement: chunked HTTP on the
    /// outside, multiplexed frames on the inside, split at an awkward offset.
    @Test("the two layers compose over a real log response", arguments: [1, 6, 11, 512])
    func chunkedThenMultiplexed(splitEvery: Int) throws {
        let frames = [
            RawResponses.logFrame(stream: 1, payload: Data("starting worker\n".utf8)),
            RawResponses.logFrame(stream: 2, payload: Data("SQLSTATE[HY000] connection refused\n".utf8)),
            RawResponses.logFrame(stream: 1, payload: Data("exiting\n".utf8)),
        ]
        let response = RawResponses.multiplexedLogResponse(frames: frames)

        var parser = ThrallHTTPResponseParser()
        var head: ThrallHTTPResponseHead?
        var decoder: ThrallLogFrameDecoder?
        var decoded: [ThrallLogFrame] = []

        var index = response.startIndex
        while index < response.endIndex {
            let end = min(index + splitEvery, response.endIndex)
            for event in try parser.feed(Data(response[index..<end])) {
                switch event {
                case .head(let value):
                    head = value
                    let framing = try #require(
                        ThrallLogFrameDecoder.framing(forContentType: value.contentType))
                    decoder = ThrallLogFrameDecoder(framing: framing)
                case .body(let chunk):
                    // Force-unwrapped through the optional so `feed`'s mutation
                    // lands on the stored decoder: `#require` would hand back a
                    // copy and silently lose the carry buffer.
                    #expect(decoder != nil, "body arrived before the head")
                    if decoder != nil {
                        decoded += try decoder!.feed(chunk)
                    }
                default:
                    break
                }
            }
            index = end
        }
        #expect(try #require(head).contentType == ThrallLogFrameDecoder.multiplexedContentType)
        #expect(decoded.map(\.stream) == [.stdout, .stderr, .stdout])
        #expect(decoded.map { String(decoding: $0.payload, as: UTF8.self) }
            == ["starting worker\n", "SQLSTATE[HY000] connection refused\n", "exiting\n"])
    }
}
