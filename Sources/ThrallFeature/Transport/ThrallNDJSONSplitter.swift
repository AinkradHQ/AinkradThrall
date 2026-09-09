import Foundation

/// Splits a byte stream into newline-delimited JSON documents.
///
/// It sits **above** the dechunker and keeps its own carry buffer, because one
/// chunk is emphatically not one event. Measured on this machine: `/events`
/// produced 256 events in an hour and every one carried the emitting
/// container's full label set, so single events routinely exceed 1 KB while
/// chunks arrive at whatever size the engine's writer flushed. Treating a
/// `.body` emission as a record boundary would split events mid-object and
/// concatenate others.
///
/// Blank lines are dropped rather than reported. The engine sends none, but a
/// keep-alive newline is a normal thing for a long-poll to send and it is not
/// a document.
public struct ThrallNDJSONSplitter {
    /// Caps the carry buffer. A peer that never sends a newline would
    /// otherwise grow this without bound for as long as the stream is open,
    /// which on `/events` is the whole session.
    public let maximumLineLength: Int
    private var carry = Data()

    public init(maximumLineLength: Int = 4 * 1024 * 1024) {
        self.maximumLineLength = maximumLineLength
    }

    /// Returns every complete line the new bytes finished, in order. A
    /// trailing partial line stays in the carry buffer.
    public mutating func feed(_ bytes: Data) throws -> [Data] {
        carry.append(bytes)
        var lines: [Data] = []
        var searchStart = carry.startIndex
        while let newline = carry[searchStart..<carry.endIndex].firstIndex(of: 0x0A) {
            var lineEnd = newline
            if lineEnd > searchStart, carry[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if lineEnd > searchStart {
                lines.append(Data(carry[searchStart..<lineEnd]))
            }
            searchStart = newline + 1
        }
        carry = searchStart == carry.endIndex ? Data() : Data(carry[searchStart...])
        guard carry.count <= maximumLineLength else {
            throw ThrallTransportError.tooLarge(
                "NDJSON line exceeded \(maximumLineLength) bytes without a newline")
        }
        return lines
    }

    /// Whatever is left when the stream ends. The engine terminates every
    /// event with a newline, so a non-empty result here means the stream was
    /// cut mid-record — a caller that parses it anyway gets invalid JSON,
    /// which is why it is returned rather than silently flushed as a line.
    public mutating func finish() -> Data {
        let remainder = carry
        carry = Data()
        return remainder
    }
}
