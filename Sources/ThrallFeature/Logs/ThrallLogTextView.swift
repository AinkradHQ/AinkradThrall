import SwiftUI
import AppKit
import AinkradAppKit

/// Maps the 16 ANSI slots **through the host theme**, so a log pane follows
/// the user's colours like every other Ainkrad surface.
///
/// Slots 1/9 (red) and 3/11 (yellow) come from the status colours the rest of
/// the app already uses for danger and warning, so an error line in a log is
/// the same red as an error badge beside it. The rest are derived from theme
/// tokens rather than picked, which is what keeps a log from looking like a
/// terminal someone pasted in.
struct ThrallANSIPalette {
    let colors: [Color]

    init(theme: HostThemeTokens, statusColors: AinkradStatusColors) {
        let foreground = theme.foreground
        let danger = AinkradStatus.danger.color(in: theme, statusColors: statusColors)
        let warning = AinkradStatus.warning.color(in: theme, statusColors: statusColors)
        let success = AinkradStatus.success.color(in: theme, statusColors: statusColors)
        colors = [
            foreground.opacity(0.45),   // 0 black -> dimmed foreground
            danger,                     // 1 red
            success,                    // 2 green
            warning,                    // 3 yellow
            theme.accentPrimary,        // 4 blue
            theme.accentSecondary,      // 5 magenta
            theme.accentPrimary.opacity(0.8), // 6 cyan
            foreground,                 // 7 white
            foreground.opacity(0.6),    // 8 bright black
            danger,                     // 9
            success,                    // 10
            warning,                    // 11
            theme.accentPrimary,        // 12
            theme.accentSecondary,      // 13
            theme.accentPrimary.opacity(0.9), // 14
            foreground,                 // 15
        ]
    }

    func color(slot: Int?, default fallback: Color) -> Color {
        guard let slot, slot >= 0, slot < colors.count else { return fallback }
        return colors[slot]
    }
}

/// A log pane backed by `NSTextView`.
///
/// **Not a `LazyVStack`, and this is a measured constraint rather than a
/// preference.** 24 services at follow produce hundreds of lines a second;
/// SwiftUI's diffing cannot keep up with a list whose identity set churns that
/// fast, and it drops frames long before the memory becomes a problem.
/// `NSTextView` also brings text selection, `⌘F` and copy for free — three
/// things a log pane is useless without and each of which is real work to
/// rebuild in SwiftUI.
///
/// Rendering is **whole-buffer replace on change**, not incremental append.
/// The buffer is already bounded at a few thousand lines, so building one
/// attributed string is cheap and it removes an entire class of bug: an
/// incremental appender has to reason about the ring buffer dropping lines
/// from the front at the same time, and getting that wrong scrambles the log
/// silently.
struct ThrallLogTextView: NSViewRepresentable {
    let lines: [ThrallLogLine]
    let palette: ThrallANSIPalette
    let foreground: Color
    let showsServicePrefix: Bool
    /// Follow mode. When on, the view scrolls to the bottom on every update;
    /// when off, the user's scroll position is left alone — scrolling away
    /// from the bottom is how someone reads what already happened.
    let isFollowing: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // A log is columnar output; wrapping it destroys the alignment that
        // makes it readable, so it scrolls horizontally instead.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let selected = textView.selectedRanges
        textView.textStorage?.setAttributedString(attributedLog())
        // Preserving the selection matters: without it a follow tick wipes
        // whatever the user was in the middle of copying.
        if !isFollowing {
            textView.selectedRanges = selected
        }
        if isFollowing {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// A fixed-width service column, because alignment is what makes a
    /// multi-service tail readable.
    ///
    /// Truncation is **marked**. The first version padded to `min(14, ...)`,
    /// which always cut to 14 and silently turned `runtime-head-hunter` into
    /// `runtime-head-h` — a service name that does not exist. A name the user
    /// cannot match against their compose file is worse than a wider column.
    static func prefix(_ service: String, width: Int = 16) -> String {
        guard service.count > width else {
            return service.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        return String(service.prefix(width - 1)) + "\u{2026}"
    }

    private func attributedLog() -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let defaultColor = NSColor(foreground)
        let output = NSMutableAttributedString()

        for line in lines {
            if showsServicePrefix, let service = line.service {
                output.append(NSAttributedString(
                    string: Self.prefix(service) + " ",
                    attributes: [.font: font,
                                 .foregroundColor: defaultColor.withAlphaComponent(0.45)]))
            }
            for run in line.runs {
                var color = NSColor(palette.color(slot: run.colorSlot, default: foreground))
                // stderr is dimmed toward danger even without a colour code,
                // because a container that does not colour its output still
                // distinguishes its streams and the user should see that.
                if run.colorSlot == nil, line.stream == .stderr {
                    color = NSColor(palette.color(slot: 1, default: foreground))
                }
                if run.isDim { color = color.withAlphaComponent(0.6) }
                output.append(NSAttributedString(
                    string: run.text,
                    attributes: [.font: run.isBold ? boldFont : font,
                                 .foregroundColor: color]))
            }
            output.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        return output
    }
}
