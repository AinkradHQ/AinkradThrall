import Foundation

/// The status line and header block of one response.
public struct ThrallHTTPResponseHead: Equatable, Sendable {
    public let statusCode: Int
    public let reasonPhrase: String
    public let headers: ThrallHTTPHeaders

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// The media type with parameters stripped, lowercased — e.g.
    /// `application/vnd.docker.multiplexed-stream`.
    ///
    /// This one value decides how a log stream is framed, and getting it wrong
    /// renders garbage rather than failing, so the normalisation lives here
    /// once instead of at each call site.
    public var contentType: String? {
        guard let raw = headers.first("Content-Type") else { return nil }
        return raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// An incremental HTTP/1.1 **response** parser: bytes in, framing events out.
///
/// It is a plain value type with no I/O and no isolation, so every hazard
/// below is reachable from a test with no daemon running. Four things about
/// the Docker engine shaped it:
///
///  1. **Chunked is the common case, not the exotic one.** A plain
///     `GET /containers/json` comes back `Transfer-Encoding: chunked` in
///     0x4000-byte chunks; only `/version` and a few small replies use
///     `Content-Length`. A parser that handles content-length first and
///     chunked "later" cannot read the primary endpoint.
///  2. **Body bytes are emitted the instant they arrive**, mid-chunk. Waiting
///     for a chunk to complete before yielding would add up to one whole chunk
///     of latency to a `follow` log stream — the user would watch output
///     arrive in 16 KB steps.
///  3. **A 101 hands over mid-buffer.** Whatever sits past the header
///     terminator in the same read is already the container's output, so it is
///     returned with `.upgraded` rather than dropped. Dropping it loses the
///     first line of a shell prompt, intermittently.
///  4. **Framing is refused, never guessed.** `Content-Length` alongside
///     `Transfer-Encoding`, a repeated and disagreeing `Content-Length`, an
///     obs-folded header, a non-hex chunk size, a chunk not followed by its
///     terminator: each throws. Once framing is lost HTTP/1.1 has no
///     resynchronisation point, so the only honest recovery is a new
///     connection — and this transport opens one per request anyway.
public struct ThrallHTTPResponseParser {
    public enum Output: Equatable, Sendable {
        case head(ThrallHTTPResponseHead)
        /// Decoded body bytes — dechunked, never empty, not necessarily
        /// aligned to any boundary the peer used.
        case body(Data)
        /// The trailer section of a chunked response, when it is non-empty.
        case trailers(ThrallHTTPHeaders)
        /// The message is complete.
        case end
        /// `101 Switching Protocols`. `residual` is the bytes already read
        /// past the header terminator: the peer's first payload. The parser
        /// accepts no further input after this.
        case upgraded(residual: Data)
    }

    /// Caps. Every one of these bounds memory against a *well-formed* peer, so
    /// they are part of the contract rather than paranoia: `/events` frames
    /// carry a container's full label set and routinely exceed 1 KB, and a
    /// desynced chunk-size line can read as a gigabyte-scale hex number.
    public struct Limits: Equatable, Sendable {
        public var maximumStatusLine: Int
        public var maximumHeaderBlock: Int
        public var maximumChunkSize: Int

        public init(
            maximumStatusLine: Int = 8 * 1024,
            maximumHeaderBlock: Int = 256 * 1024,
            maximumChunkSize: Int = 64 * 1024 * 1024
        ) {
            self.maximumStatusLine = maximumStatusLine
            self.maximumHeaderBlock = maximumHeaderBlock
            self.maximumChunkSize = maximumChunkSize
        }

        public static let `default` = Limits()
    }

    enum State: Equatable {
        case statusLine
        case headerBlock
        case fixedLengthBody(remaining: Int)
        case chunkSizeLine
        case chunkBody(remaining: Int)
        /// The CRLF that must follow a chunk's data. Its own state because it
        /// is the check that catches a desync one chunk after it happens.
        case chunkTerminator
        case trailerBlock
        /// No framing given: the body runs to end-of-connection.
        case untilClose
        case complete
        case upgraded
        case failed
    }

    let limits: Limits
    var state: State = .statusLine
    /// Unconsumed bytes. `cursor` avoids the O(n) front-removal that would
    /// otherwise dominate a long-lived stream.
    var buffer = Data()
    var cursor = 0
    private var headerBlockBytes = 0
    var statusCode = 0
    var reasonPhrase = ""
    var headers = ThrallHTTPHeaders()
    var trailers = ThrallHTTPHeaders()

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    /// True once `.end` or `.upgraded` has been emitted.
    public var isFinished: Bool {
        state == .complete || state == .upgraded
    }

    /// Feeds a read's worth of bytes and returns the framing events they
    /// completed. An empty return is normal — a partial header line produces
    /// nothing.
    public mutating func feed(_ bytes: Data) throws -> [Output] {
        switch state {
        case .failed:
            throw ThrallTransportError.malformedResponse("parser already failed")
        case .upgraded:
            throw ThrallTransportError.malformedResponse(
                "bytes fed after the connection was upgraded; read them from the hijacked stream")
        case .complete:
            guard bytes.isEmpty else {
                // No pipelining: every request carries `Connection: close`, so
                // a second message on this socket means we mis-framed the
                // first one.
                throw fail("bytes fed after the response completed (\(bytes.count) bytes)")
            }
            return []
        default:
            break
        }
        if !bytes.isEmpty {
            buffer.append(bytes)
        }
        return try drain()
    }

    /// Reports end-of-connection. For a body with no declared length this is
    /// the legitimate terminator; anywhere else it is a truncated response.
    public mutating func finish() throws -> [Output] {
        switch state {
        case .complete, .upgraded:
            return []
        case .untilClose:
            state = .complete
            buffer = Data()
            cursor = 0
            return [.end]
        case .failed:
            throw ThrallTransportError.malformedResponse("parser already failed")
        case .statusLine where buffer.count == cursor:
            // Closed before saying anything at all. Distinguished because it
            // is what an engine restart looks like, and the caller reconnects
            // rather than reporting corruption.
            state = .failed
            throw ThrallTransportError.closed
        default:
            throw fail("connection closed mid-response in state \(state)")
        }
    }

    // MARK: - The drain loop

    private mutating func drain() throws -> [Output] {
        var outputs: [Output] = []
        loop: while true {
            switch state {
            case .statusLine:
                guard let line = try takeLine(limit: limits.maximumStatusLine) else { break loop }
                try parseStatusLine(line)
                state = .headerBlock

            case .headerBlock:
                guard let line = try takeLine(limit: limits.maximumHeaderBlock) else { break loop }
                headerBlockBytes += line.utf8.count + 2
                guard headerBlockBytes <= limits.maximumHeaderBlock else {
                    throw failTooLarge("header block exceeded \(limits.maximumHeaderBlock) bytes")
                }
                if line.isEmpty {
                    let head = ThrallHTTPResponseHead(
                        statusCode: statusCode,
                        reasonPhrase: reasonPhrase,
                        headers: headers)
                    outputs.append(.head(head))
                    outputs.append(contentsOf: try enterBody(head))
                    if state == .upgraded || state == .complete { break loop }
                } else {
                    try appendField(line, toTrailers: false)
                }

            case .fixedLengthBody(let remaining):
                let take = min(remaining, available)
                if take > 0 {
                    outputs.append(.body(consume(take)))
                }
                if take == remaining {
                    state = .complete
                    outputs.append(.end)
                    break loop
                }
                state = .fixedLengthBody(remaining: remaining - take)
                break loop

            case .chunkSizeLine:
                guard let line = try takeLine(limit: limits.maximumStatusLine) else { break loop }
                let size = try parseChunkSize(line)
                if size == 0 {
                    trailers = ThrallHTTPHeaders()
                    state = .trailerBlock
                } else {
                    state = .chunkBody(remaining: size)
                }

            case .chunkBody(let remaining):
                let take = min(remaining, available)
                if take > 0 {
                    // Emitted mid-chunk on purpose — see hazard 2 in the type's
                    // documentation. Chunk boundaries carry no meaning to any
                    // consumer above this seam.
                    outputs.append(.body(consume(take)))
                }
                if take == remaining {
                    state = .chunkTerminator
                } else {
                    state = .chunkBody(remaining: remaining - take)
                    break loop
                }

            case .chunkTerminator:
                // A generous limit on purpose: a desync here should surface as
                // "not followed by CRLF" with the offending bytes quoted, not
                // as a size complaint.
                guard let line = try takeLine(limit: 8) else { break loop }
                guard line.isEmpty else {
                    throw fail("chunk data was not followed by CRLF (saw \(line.debugDescription))")
                }
                state = .chunkSizeLine

            case .trailerBlock:
                guard let line = try takeLine(limit: limits.maximumHeaderBlock) else { break loop }
                if line.isEmpty {
                    if !trailers.fields.isEmpty {
                        outputs.append(.trailers(trailers))
                    }
                    state = .complete
                    outputs.append(.end)
                    break loop
                }
                try appendField(line, toTrailers: true)

            case .untilClose:
                if available > 0 {
                    outputs.append(.body(consume(available)))
                }
                break loop

            case .complete, .upgraded, .failed:
                break loop
            }
        }
        compact()
        return outputs
    }
}
