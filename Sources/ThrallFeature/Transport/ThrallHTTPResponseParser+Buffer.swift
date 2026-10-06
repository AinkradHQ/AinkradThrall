import Foundation

extension ThrallHTTPResponseParser {
    // MARK: - Buffer primitives

    var available: Int { buffer.count - cursor }

    /// Consumes the next CRLF- or LF-terminated line, without its terminator.
    /// Returns nil (consuming nothing) when no terminator is buffered yet.
    ///
    /// A bare LF is accepted deliberately: Podman's compat layer and any proxy
    /// in front of a remote engine are outside our control, and leniency here
    /// costs nothing because desync is caught by *content* checks — hex
    /// validity, the chunk terminator, the multiplexed frame's zero padding —
    /// not by line endings.
    mutating func takeLine(limit: Int) throws -> String? {
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

    mutating func consume(_ count: Int) -> Data {
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
    mutating func compact() {
        guard cursor > 0 else { return }
        if cursor == buffer.count {
            buffer = Data()
            cursor = 0
        } else if cursor >= 16 * 1024 {
            buffer = Data(buffer[(buffer.startIndex + cursor)...])
            cursor = 0
        }
    }

    mutating func fail(_ reason: String) -> ThrallTransportError {
        state = .failed
        return .malformedResponse(reason)
    }

    mutating func failTooLarge(_ reason: String) -> ThrallTransportError {
        state = .failed
        return .tooLarge(reason)
    }
}
