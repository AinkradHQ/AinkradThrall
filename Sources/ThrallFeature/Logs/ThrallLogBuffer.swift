import Foundation

/// One line of container output, ready to render.
public struct ThrallLogLine: Equatable, Sendable, Identifiable {
    public let id: Int
    public let stream: ThrallLogStream
    /// Which service produced it. Non-nil only for a multi-service tail, where
    /// it becomes the line's prefix.
    public let service: String?
    public let runs: [ThrallStyledRun]

    public var plainText: String { runs.map(\.text).joined() }
}

/// A bounded, append-only line store.
///
/// **A ring buffer, and the bound is the point.** 24 services at follow produce
/// hundreds of lines a second; an unbounded store is an out-of-memory in a few
/// minutes, and a SwiftUI list diffing it dies long before that. Dropping the
/// oldest lines is the correct behaviour for a log tail — that is what `tail`
/// means.
public struct ThrallLogBuffer {
    public let capacity: Int
    private var lines: [ThrallLogLine] = []
    private var nextID = 0
    /// Partial trailing text per service, since a read boundary lands
    /// mid-line constantly.
    private var carry: [String: String] = [:]
    private var parsers: [String: ThrallANSIParser] = [:]
    public private(set) var droppedLines = 0

    public init(capacity: Int = 5_000) {
        self.capacity = max(1, capacity)
        lines.reserveCapacity(min(self.capacity, 1_024))
    }

    public var all: [ThrallLogLine] { lines }
    public var count: Int { lines.count }

    /// Appends a decoded frame, splitting it into lines.
    ///
    /// `service` keys the carry buffer and the parser state, so two services
    /// interleaving on one pane cannot inherit each other's half-line or
    /// colour.
    public mutating func append(frame: ThrallLogFrame, service: String?) {
        let key = service ?? ""
        // **CRLF is normalised before any line splitting**, and it has to be:
        // Swift treats "\r\n" as a single grapheme cluster, so
        // `firstIndex(of: "\n")` does not find it and a CRLF-terminated log
        // arrives as one unbroken line. This is the second place that
        // grapheme rule has bitten — the first was the header-value check in
        // `ThrallHTTPRequest`. Any code here that reasons about line endings
        // must work on normalised text or on scalars, never on `Character`.
        let text = String(decoding: frame.payload, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var pending = (carry[key] ?? "") + text
        var completed: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<newline])
            // A bare CR is a progress bar overwriting its own line (a `pull`
            // does this constantly). Keeping only the text after the last one
            // is what a terminal shows, and stops one download turning into a
            // single 200 KB line.
            completed.append(line.contains("\r")
                             ? String(line.split(separator: "\r").last ?? "")
                             : line)
            pending = String(pending[pending.index(after: newline)...])
        }
        // A line longer than this is a minified blob or a base64 payload, and
        // holding it whole would let one line defeat the whole cap.
        if pending.count > 8 * 1024 {
            completed.append(String(pending.prefix(8 * 1024)))
            pending = ""
        }
        carry[key] = pending

        var parser = parsers[key] ?? ThrallANSIParser()
        for line in completed {
            let runs = parser.parse(line)
            push(ThrallLogLine(id: nextID, stream: frame.stream, service: service,
                               runs: runs.isEmpty
                                   ? [ThrallStyledRun(colorSlot: nil, text: "")]
                                   : runs))
            nextID += 1
        }
        parsers[key] = parser
    }

    private mutating func push(_ line: ThrallLogLine) {
        lines.append(line)
        guard lines.count > capacity else { return }
        let excess = lines.count - capacity
        lines.removeFirst(excess)
        droppedLines += excess
    }

    /// Flushes any partial trailing line, for when a stream ends.
    public mutating func flush() {
        for (key, pending) in carry where !pending.isEmpty {
            var parser = parsers[key] ?? ThrallANSIParser()
            push(ThrallLogLine(id: nextID, stream: .stdout,
                               service: key.isEmpty ? nil : key,
                               runs: parser.parse(pending)))
            nextID += 1
            parsers[key] = parser
        }
        carry = [:]
    }

    public mutating func clear() {
        lines.removeAll(keepingCapacity: true)
        carry = [:]
        parsers = [:]
        droppedLines = 0
    }

    /// Case-insensitive substring filter over plain text.
    public func filtered(_ query: String) -> [ThrallLogLine] {
        guard !query.isEmpty else { return lines }
        let needle = query.lowercased()
        return lines.filter { $0.plainText.lowercased().contains(needle) }
    }
}
