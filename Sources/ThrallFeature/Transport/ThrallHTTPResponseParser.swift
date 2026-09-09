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

        public init(maximumStatusLine: Int = 8 * 1024,
                    maximumHeaderBlock: Int = 256 * 1024,
                    maximumChunkSize: Int = 64 * 1024 * 1024) {
            self.maximumStatusLine = maximumStatusLine
            self.maximumHeaderBlock = maximumHeaderBlock
            self.maximumChunkSize = maximumChunkSize
        }

        public static let `default` = Limits()
    }

    private enum State: Equatable {
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

    private let limits: Limits
    private var state: State = .statusLine
    /// Unconsumed bytes. `cursor` avoids the O(n) front-removal that would
    /// otherwise dominate a long-lived stream.
    private var buffer = Data()
    private var cursor = 0
    private var headerBlockBytes = 0
    private var statusCode = 0
    private var reasonPhrase = ""
    private var headers = ThrallHTTPHeaders()
    private var trailers = ThrallHTTPHeaders()

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
                    let head = ThrallHTTPResponseHead(statusCode: statusCode,
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

    // MARK: - Framing decisions

    /// Chooses the body framing from the head, per RFC 9112 6.3 narrowed to
    /// what the Docker engine actually emits.
    private mutating func enterBody(_ head: ThrallHTTPResponseHead) throws -> [Output] {
        if statusCode == 101 {
            state = .upgraded
            let residual = available > 0 ? consume(available) : Data()
            return [.upgraded(residual: residual)]
        }
        if statusCode >= 100 && statusCode < 200 {
            // Thrall never sends `Expect: 100-continue` and the engine sends no
            // other 1xx, so one arriving means we are reading something other
            // than what we think.
            throw fail("unexpected informational response \(statusCode)")
        }
        // A body-less status: 204 and 304 carry no body regardless of what
        // their headers claim.
        if statusCode == 204 || statusCode == 304 {
            state = .complete
            return [.end]
        }

        let transferEncodings = head.headers.values("Transfer-Encoding")
        let contentLengths = head.headers.values("Content-Length")

        if !transferEncodings.isEmpty {
            guard contentLengths.isEmpty else {
                // RFC 9112 6.1: this combination must be treated as an error.
                // On a root-equivalent local socket it is not a theoretical
                // one.
                throw fail("both Transfer-Encoding and Content-Length are present")
            }
            let encodings = transferEncodings
                .flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            guard encodings == ["chunked"] else {
                // `gzip, chunked` would need a decompressor this transport does
                // not have. Refuse rather than hand a caller compressed bytes
                // it will try to parse as JSON.
                throw ThrallTransportError.unsupportedFraming(
                    "Transfer-Encoding: \(encodings.joined(separator: ", "))")
            }
            state = .chunkSizeLine
            return []
        }

        if !contentLengths.isEmpty {
            let parsed = try contentLengths.map { try parseContentLength($0) }
            guard Set(parsed).count == 1 else {
                throw fail("Content-Length repeated with different values: \(parsed)")
            }
            let length = parsed[0]
            if length == 0 {
                // The engine's 301 redirect for a mis-typed path is exactly
                // this, and it must complete rather than wait for a body.
                state = .complete
                return [.end]
            }
            state = .fixedLengthBody(remaining: length)
            return []
        }

        state = .untilClose
        return []
    }

    private func parseContentLength(_ raw: String) throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Digits only: `Int(_:)` would accept `+5` and `-0`, and a signed or
        // padded length is a framing trick, not a typo.
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII),
              trimmed.allSatisfy({ $0.isNumber }), let value = Int(trimmed), value >= 0 else {
            throw ThrallTransportError.malformedResponse("Content-Length is not a length: \(raw)")
        }
        return value
    }

    // MARK: - Line parsing

    private mutating func parseStatusLine(_ line: String) throws {
        // `HTTP/1.1 200 OK`, and the reason phrase is legally empty.
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1.") else {
            throw fail("not an HTTP/1.x status line: \(line.debugDescription)")
        }
        let code = parts[1]
        guard code.count == 3, code.allSatisfy({ $0.isNumber }), let value = Int(code) else {
            throw fail("status code is not three digits: \(code.debugDescription)")
        }
        statusCode = value
        reasonPhrase = parts.count == 3 ? String(parts[2]) : ""
    }

    /// Parses one field line and appends it to the header or trailer section.
    ///
    /// Takes a flag rather than an `inout ThrallHTTPHeaders`, because passing
    /// one of `self`'s own properties by reference to a `mutating` method is
    /// an exclusivity violation — and the compiler is right: `fail()` writes
    /// `state` on the same `self` mid-call.
    private mutating func appendField(_ line: String, toTrailers: Bool) throws {
        guard let first = line.first, first != " ", first != "\t" else {
            // obs-fold. RFC 9112 5.2 says a recipient MUST reject it in a
            // response it forwards and MAY replace it with SP; refusing is the
            // only reading with no ambiguity about where a value ends.
            throw fail("obs-folded header line: \(line.debugDescription)")
        }
        guard let colon = line.firstIndex(of: ":") else {
            throw fail("header line has no colon: \(line.debugDescription)")
        }
        let name = String(line[line.startIndex..<colon])
        guard !name.isEmpty, !name.hasSuffix(" "), !name.hasSuffix("\t") else {
            // Whitespace before the colon is forbidden (RFC 9112 5.1) and is a
            // classic smuggling shape.
            throw fail("header name is empty or padded: \(name.debugDescription)")
        }
        let value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        if toTrailers {
            trailers.append(name: name, value: value)
        } else {
            headers.append(name: name, value: value)
        }
    }

    private mutating func parseChunkSize(_ line: String) throws -> Int {
        // `4000` or `4000;name=value` — extensions are legal and ignored.
        let sizeField = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        guard !sizeField.isEmpty, sizeField.count <= 16,
              sizeField.allSatisfy({ $0.isHexDigit }), let size = Int(sizeField, radix: 16) else {
            throw fail("chunk size is not hex: \(line.debugDescription)")
        }
        guard size <= limits.maximumChunkSize else {
            throw failTooLarge("chunk size \(size) exceeds \(limits.maximumChunkSize)")
        }
        return size
    }

    // MARK: - Buffer primitives

    private var available: Int { buffer.count - cursor }

    /// Consumes the next CRLF- or LF-terminated line, without its terminator.
    /// Returns nil (consuming nothing) when no terminator is buffered yet.
    ///
    /// A bare LF is accepted deliberately: Podman's compat layer and any proxy
    /// in front of a remote engine are outside our control, and leniency here
    /// costs nothing because desync is caught by *content* checks — hex
    /// validity, the chunk terminator, the multiplexed frame's zero padding —
    /// not by line endings.
    private mutating func takeLine(limit: Int) throws -> String? {
        let start = buffer.startIndex + cursor
        let end = buffer.endIndex
        guard start < end else { return nil }
        guard let newline = buffer[start..<end].firstIndex(of: 0x0A) else {
            guard available <= max(limit, 2) else {
                throw failTooLarge("no line terminator within \(limit) bytes")
            }
            return nil
        }
        var lineEnd = newline
        if lineEnd > start, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }
        let raw = buffer[start..<lineEnd]
        guard raw.count <= limit else {
            throw failTooLarge("line of \(raw.count) bytes exceeds \(limit)")
        }
        cursor += (newline - start) + 1
        // Header bytes are ASCII by definition; a lossy decode here turns an
        // encoding oddity into a mangled field rather than a parse failure,
        // which is the right trade for a value we go on to validate.
        return String(decoding: raw, as: UTF8.self)
    }

    private mutating func consume(_ count: Int) -> Data {
        let start = buffer.startIndex + cursor
        let slice = buffer[start..<(start + count)]
        cursor += count
        // Re-wrapped so the returned value does not retain the whole buffer's
        // storage — a `Data` slice does, and on a follow stream that would pin
        // every byte ever read.
        return Data(slice)
    }

    /// Drops consumed bytes. Only when the cursor has run out or grown past a
    /// page, so the common case is a no-op rather than a copy per read.
    private mutating func compact() {
        guard cursor > 0 else { return }
        if cursor == buffer.count {
            buffer = Data()
            cursor = 0
        } else if cursor >= 16 * 1024 {
            buffer = Data(buffer[(buffer.startIndex + cursor)...])
            cursor = 0
        }
    }

    private mutating func fail(_ reason: String) -> ThrallTransportError {
        state = .failed
        return .malformedResponse(reason)
    }

    private mutating func failTooLarge(_ reason: String) -> ThrallTransportError {
        state = .failed
        return .tooLarge(reason)
    }
}
