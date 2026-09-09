import Foundation
import Testing
@testable import ThrallFeature

@Suite("ThrallANSIParser")
struct ThrallANSIParserTests {
    private func runs(_ text: String) -> [ThrallStyledRun] {
        var parser = ThrallANSIParser()
        return parser.parse(text)
    }

    @Test("plain text is one run with no colour")
    func plainText() {
        #expect(runs("starting worker") == [ThrallStyledRun(colorSlot: nil,
                                                            text: "starting worker")])
    }

    /// Slot indices, never colours — the mapping happens through the theme at
    /// render time so a log follows the user's colours.
    @Test("standard and bright foreground codes map to slots", arguments: [
        ("\u{1B}[31mred", 1), ("\u{1B}[32mgreen", 2), ("\u{1B}[33myellow", 3),
        ("\u{1B}[91mbright", 9), ("\u{1B}[97mwhite", 15),
    ])
    func colorSlots(text: String, slot: Int) {
        #expect(runs(text).last?.colorSlot == slot)
    }

    @Test("reset clears colour and weight")
    func reset() {
        let parsed = runs("\u{1B}[1;31mbad\u{1B}[0m fine")
        #expect(parsed.count == 2)
        #expect(parsed[0].colorSlot == 1)
        #expect(parsed[0].isBold)
        #expect(parsed[1].colorSlot == nil)
        #expect(!parsed[1].isBold)
    }

    @Test("a bare ESC[m is a reset")
    func bareReset() {
        let parsed = runs("\u{1B}[31mred\u{1B}[mplain")
        #expect(parsed.last?.colorSlot == nil)
    }

    /// **A colour code split across two reads would otherwise print as
    /// literal text**, which is what a log looks like when a chunk boundary
    /// lands inside an escape — and with a dechunker above, it lands there
    /// constantly.
    @Test("an escape split across chunks is reassembled", arguments: [1, 2, 3, 4, 5])
    func splitEscape(splitAt: Int) {
        let text = "\u{1B}[31mfailed"
        var parser = ThrallANSIParser()
        let head = String(text.prefix(splitAt))
        let tail = String(text.dropFirst(splitAt))
        var collected = parser.parse(head)
        collected += parser.parse(tail)
        #expect(collected.map(\.text).joined() == "failed")
        #expect(collected.last?.colorSlot == 1)
    }

    /// A log that picks colour 208 is decorating; honouring it would put a
    /// colour outside the theme on screen.
    @Test("256-colour and truecolour fold onto the 16 slots")
    func extendedColors() {
        #expect(runs("\u{1B}[38;5;208mwarn").last?.colorSlot == 208 % 16)
        // Truecolour is consumed without leaking its parameters as text.
        #expect(runs("\u{1B}[38;2;255;0;0mred").last?.text == "red")
    }

    /// A log that sets its own background fights the pane's, and the pane's is
    /// the one the user chose.
    @Test("background colours are ignored, not printed")
    func backgroundIgnored() {
        let parsed = runs("\u{1B}[41mtext")
        #expect(parsed.map(\.text).joined() == "text")
        #expect(parsed.last?.colorSlot == nil)
    }

    /// Cursor movement is what a *terminal* needs. Thrall is not one —
    /// interactive exec hands off to Rune.
    @Test("cursor and erase sequences are dropped, not rendered",
          arguments: ["\u{1B}[2J", "\u{1B}[H", "\u{1B}[1A", "\u{1B}[K"])
    func nonSGRDropped(sequence: String) {
        #expect(runs("before\(sequence)after").map(\.text).joined() == "beforeafter")
    }

    @Test("a stray escape byte is not printed")
    func strayEscape() {
        #expect(runs("a\u{1B}Xb").map(\.text).joined() == "ab")
    }
}

@Suite("ThrallLogBuffer")
struct ThrallLogBufferTests {
    private func frame(_ text: String, stream: ThrallLogStream = .stdout) -> ThrallLogFrame {
        ThrallLogFrame(stream: stream, payload: Data(text.utf8))
    }

    @Test("frames split into lines")
    func splitsLines() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame("one\ntwo\nthree\n"), service: nil)
        #expect(buffer.all.map(\.plainText) == ["one", "two", "three"])
    }

    /// A read boundary lands mid-line constantly, so the carry buffer is the
    /// normal path rather than an edge case.
    @Test("a line split across frames is joined")
    func joinsAcrossFrames() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame("par"), service: nil)
        buffer.append(frame: frame("tial\n"), service: nil)
        #expect(buffer.all.map(\.plainText) == ["partial"])
    }

    /// **Swift treats "\r\n" as a single grapheme cluster**, so a naive
    /// `firstIndex(of: "\n")` does not find it and a CRLF log arrives as one
    /// unbroken line. Second time that rule has bitten in this codebase.
    @Test("CRLF endings lose the carriage return")
    func crlf() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame("line one\r\nline two\r\n"), service: nil)
        #expect(buffer.all.map(\.plainText) == ["line one", "line two"])
    }

    /// A `pull` overwrites its progress line with bare CRs. Keeping only the
    /// final segment is what a terminal shows, and stops one download
    /// becoming a single 200 KB line.
    @Test("a bare CR keeps only the last segment, like a terminal")
    func bareCarriageReturn() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame("10%\r50%\r100% done\n"), service: nil)
        #expect(buffer.all.map(\.plainText) == ["100% done"])
    }

    /// **The bound is the point.** 24 services at follow produce hundreds of
    /// lines a second; unbounded is an out-of-memory in minutes.
    @Test("the buffer is capped and drops the oldest")
    func capped() {
        var buffer = ThrallLogBuffer(capacity: 100)
        for index in 0..<1_000 {
            buffer.append(frame: frame("line \(index)\n"), service: nil)
        }
        #expect(buffer.count == 100)
        #expect(buffer.all.first?.plainText == "line 900")
        #expect(buffer.droppedLines == 900)
    }

    /// One enormous line must not defeat the cap.
    @Test("an absurdly long line is truncated rather than held whole")
    func longLineTruncated() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame(String(repeating: "x", count: 40_000)), service: nil)
        #expect(buffer.count == 1)
        #expect(buffer.all[0].plainText.count <= 8 * 1024)
    }

    /// Two services interleaving on one pane must not inherit each other's
    /// half-line or colour state.
    @Test("carry and colour state are per service")
    func perServiceState() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame("\u{1B}[31mfrom-a-par"), service: "a")
        buffer.append(frame: frame("from-b\n"), service: "b")
        buffer.append(frame: frame("t\n"), service: "a")
        let byService = Dictionary(grouping: buffer.all, by: { $0.service ?? "" })
        #expect(byService["b"]?.map(\.plainText) == ["from-b"])
        #expect(byService["a"]?.map(\.plainText) == ["from-a-part"])
        // b's line is uncoloured even though a had set red.
        #expect(byService["b"]?.first?.runs.first?.colorSlot == nil)
        #expect(byService["a"]?.first?.runs.first?.colorSlot == 1)
    }

    @Test("stderr frames keep their stream, so the view can dim them")
    func streamPreserved() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame("bad\n", stream: .stderr), service: nil)
        #expect(buffer.all.first?.stream == .stderr)
    }

    @Test("flush emits a trailing partial line")
    func flush() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame("no newline"), service: nil)
        #expect(buffer.count == 0)
        buffer.flush()
        #expect(buffer.all.map(\.plainText) == ["no newline"])
    }

    @Test("the filter is case-insensitive over plain text, ignoring colour")
    func filtering() {
        var buffer = ThrallLogBuffer()
        buffer.append(frame: frame("\u{1B}[31mConnection REFUSED\u{1B}[0m\nall good\n"),
                      service: nil)
        #expect(buffer.filtered("refused").count == 1)
        #expect(buffer.filtered("good").count == 1)
        #expect(buffer.filtered("").count == 2)
        // The escape itself must not be matchable.
        #expect(buffer.filtered("31m").isEmpty)
    }

    @Test("ids are unique so the view cannot drop lines")
    func uniqueIDs() {
        var buffer = ThrallLogBuffer(capacity: 50)
        for index in 0..<200 { buffer.append(frame: frame("l\(index)\n"), service: nil) }
        #expect(Set(buffer.all.map(\.id)).count == buffer.count)
    }

    /// The AC's shape: 24 services at follow. Bounded memory is the assertion
    /// a test can actually make; the frame rate is what `NSTextView` is for.
    @Test("a 24-service burst stays bounded")
    func twentyFourServiceBurst() {
        var buffer = ThrallLogBuffer(capacity: 5_000)
        for tick in 0..<500 {
            for service in 1...24 {
                buffer.append(frame: frame("worker-\(service) tick \(tick)\n"),
                              service: "worker-\(service)")
            }
        }
        #expect(buffer.count == 5_000)
        #expect(buffer.droppedLines == 12_000 - 5_000)
        // And every retained line is intact — the cap must not corrupt.
        #expect(buffer.all.allSatisfy { $0.plainText.contains("tick") })
    }

    @Test("clear resets everything, including the dropped count")
    func clear() {
        var buffer = ThrallLogBuffer(capacity: 10)
        for index in 0..<50 { buffer.append(frame: frame("l\(index)\n"), service: nil) }
        buffer.clear()
        #expect(buffer.count == 0)
        #expect(buffer.droppedLines == 0)
    }
}


@Suite("Log service column")
struct ThrallLogPrefixTests {
    /// The first version padded to `min(14, ...)`, which always cut to 14 and
    /// silently turned `runtime-head-hunter` into `runtime-head-h` — a service
    /// name that does not exist in any compose file. Caught by screenshot.
    @Test("a long service name is truncated visibly, not silently")
    func longNameIsMarked() {
        let rendered = ThrallLogTextView.prefix("runtime-head-hunter")
        #expect(rendered.count == 16)
        #expect(rendered.hasSuffix("\u{2026}"))
        #expect(!rendered.hasSuffix("h"), "the old behaviour looked like a real, shorter name")
    }

    @Test("a short name is padded to the column width, keeping alignment")
    func shortNamePadded() {
        #expect(ThrallLogTextView.prefix("api") == "api             ")
        #expect(ThrallLogTextView.prefix("api").count == 16)
    }

    @Test("a name exactly at the width is untouched")
    func exactWidth() {
        let name = String(repeating: "x", count: 16)
        #expect(ThrallLogTextView.prefix(name) == name)
    }
}
