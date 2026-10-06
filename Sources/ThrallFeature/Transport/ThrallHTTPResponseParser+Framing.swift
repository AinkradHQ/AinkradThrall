import Foundation

extension ThrallHTTPResponseParser {
    // MARK: - Framing decisions

    /// Chooses the body framing from the head, per RFC 9112 6.3 narrowed to
    /// what the Docker engine actually emits.
    mutating func enterBody(_ head: ThrallHTTPResponseHead) throws -> [Output] {
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
            let encodings =
                transferEncodings
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
            trimmed.allSatisfy({ $0.isNumber }), let value = Int(trimmed), value >= 0
        else {
            throw ThrallTransportError.malformedResponse("Content-Length is not a length: \(raw)")
        }
        return value
    }

    // MARK: - Line parsing

    mutating func parseStatusLine(_ line: String) throws {
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
    mutating func appendField(_ line: String, toTrailers: Bool) throws {
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

    mutating func parseChunkSize(_ line: String) throws -> Int {
        // `4000` or `4000;name=value` — extensions are legal and ignored.
        let sizeField = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        guard !sizeField.isEmpty, sizeField.count <= 16,
            sizeField.allSatisfy({ $0.isHexDigit }), let size = Int(sizeField, radix: 16)
        else {
            throw fail("chunk size is not hex: \(line.debugDescription)")
        }
        guard size <= limits.maximumChunkSize else {
            throw failTooLarge("chunk size \(size) exceeds \(limits.maximumChunkSize)")
        }
        return size
    }
}
