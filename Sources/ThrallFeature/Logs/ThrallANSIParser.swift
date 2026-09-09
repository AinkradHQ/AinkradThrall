import Foundation

/// One run of text with a single style.
public struct ThrallStyledRun: Equatable, Sendable {
    /// Index into the 16-slot ANSI palette, or nil for the default colour.
    public let colorSlot: Int?
    public let isBold: Bool
    public let isDim: Bool
    public let text: String

    public init(colorSlot: Int?, isBold: Bool = false, isDim: Bool = false, text: String) {
        self.colorSlot = colorSlot
        self.isBold = isBold
        self.isDim = isDim
        self.text = text
    }
}

/// Turns a container's output into styled runs.
///
/// **Emits slot *indices*, never colours.** The 16 slots are mapped through
/// the host theme at render time (`ThrallANSIPalette`), so a log follows the
/// user's theme like every other surface. Hardcoding `.red` here is the thing
/// that makes a terminal pane look like it belongs to a different application.
///
/// Scope is deliberately narrow: SGR colour and weight, which is what
/// application logs actually emit. Cursor movement, scroll regions and
/// alternate screens are what a *terminal* needs, and Thrall is not one —
/// interactive exec hands off to Rune, which owns a real emulator.
public struct ThrallANSIParser {
    /// Carries an unterminated escape across a chunk boundary. A colour code
    /// split across two reads would otherwise be printed as literal text.
    private var pendingEscape = ""
    private var colorSlot: Int?
    private var isBold = false
    private var isDim = false

    public init() {}

    /// Parses a chunk, returning the runs it completed.
    public mutating func parse(_ text: String) -> [ThrallStyledRun] {
        var runs: [ThrallStyledRun] = []
        var current = ""
        // The carried escape is prepended before it is cleared, so a colour
        // code split across two reads is reassembled instead of printed.
        let buffer = Array(pendingEscape + text)
        pendingEscape = ""

        var index = 0
        while index < buffer.count {
            let character = buffer[index]
            guard character == "\u{1B}" else {
                current.append(character)
                index += 1
                continue
            }
            // An escape at the very end of a chunk: hold it rather than print it.
            guard index + 1 < buffer.count else {
                pendingEscape = String(buffer[index...])
                break
            }
            guard buffer[index + 1] == "[" else {
                // Not a CSI sequence. Skipped rather than printed — a stray
                // escape byte in a log is noise, not content.
                index += 2
                continue
            }
            var cursor = index + 2
            var parameters = ""
            while cursor < buffer.count, !buffer[cursor].isLetter {
                parameters.append(buffer[cursor])
                cursor += 1
            }
            guard cursor < buffer.count else {
                // Truncated mid-sequence.
                pendingEscape = String(buffer[index...])
                break
            }
            let final = buffer[cursor]
            if final == "m" {
                if !current.isEmpty {
                    runs.append(ThrallStyledRun(colorSlot: colorSlot, isBold: isBold,
                                                isDim: isDim, text: current))
                    current = ""
                }
                apply(parameters: parameters)
            }
            // Every other final byte (cursor moves, erases) is dropped.
            index = cursor + 1
        }
        if !current.isEmpty {
            runs.append(ThrallStyledRun(colorSlot: colorSlot, isBold: isBold,
                                        isDim: isDim, text: current))
        }
        return runs
    }

    private mutating func apply(parameters: String) {
        // An empty parameter list means `ESC[m`, which is a reset.
        let codes = parameters.isEmpty
            ? [0]
            : parameters.split(separator: ";", omittingEmptySubsequences: false)
                .map { Int($0) ?? 0 }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: colorSlot = nil; isBold = false; isDim = false
            case 1: isBold = true
            case 2: isDim = true
            case 22: isBold = false; isDim = false
            case 30...37: colorSlot = code - 30
            case 39: colorSlot = nil
            case 90...97: colorSlot = code - 90 + 8
            case 38:
                // `38;5;N` (256-colour) and `38;2;r;g;b`. Folded onto the 16
                // slots rather than expanded: a log that picks colour 208 is
                // decorating, and honouring it would put a colour outside the
                // theme on screen.
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    colorSlot = codes[index + 2] % 16
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    index += 4
                }
            case 40...47, 100...107, 48:
                // Background colour is ignored on purpose: a log that sets its
                // own background fights the pane's, and the pane's is the one
                // the user chose.
                break
            default: break
            }
            index += 1
        }
    }
}
