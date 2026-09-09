import SwiftUI
import AinkradAppKit

/// The logs area.
///
/// **Its own area, not a tab inside a stack.** "What happened at 14:32 across
/// two stacks" cannot be answered from inside one stack, and that is the
/// question a log pane exists for.
struct LogsView: View {
    @ObservedObject var model: ThrallViewModel
    @ObservedObject var logs: ThrallLogsModel

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    /// Selection is by stack; the pane tails every container in it. A
    /// per-service picker is a later refinement — the cross-stack question
    /// comes first.
    @State private var selected: ThrallStackID?

    var body: some View {
        VStack(spacing: 0) {
            controls
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: selected) { await load() }
        .onAppear {
            if selected == nil { selected = model.world.stacks.first?.id }
        }
    }

    private var controls: some View {
        HStack(spacing: AinkradSpacing.md) {
            AinkradMenuButton(items: model.world.stacks.map { stack in
                AinkradMenuItem(title: "\(stack.displayName) (\(stack.containerCount))",
                                systemName: "square.stack.3d.up") {
                    selected = stack.id
                }
            }) {
                HStack(spacing: AinkradSpacing.xs) {
                    Text(selectedStack?.displayName ?? "Choose a stack")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.foreground.opacity(0.4))
                }
                .padding(.horizontal, AinkradSpacing.sm)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: AinkradRadius.sm, style: .continuous)
                    .fill(theme.foreground.opacity(0.06)))
            }
            .fixedSize()

            AinkradSearchField(text: $logs.filter, placeholder: "Filter lines")
                .frame(maxWidth: 260)

            Spacer(minLength: 0)

            Text(lineSummary)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(theme.foreground.opacity(0.45))

            AinkradToggleButton(isOn: $logs.isFollowing, systemName: "arrow.down.to.line",
                                title: "Follow")
            AinkradIconButton(systemName: "trash", size: 24, tooltip: "Clear") { logs.clear() }
            AinkradIconButton(systemName: "arrow.clockwise", size: 24, tooltip: "Reload") {
                Task { await load() }
            }
        }
        .padding(.horizontal, AinkradSpacing.lg)
        .padding(.vertical, AinkradSpacing.sm)
        .background(theme.surface.opacity(0.25))
    }

    @ViewBuilder
    private var content: some View {
        if let error = logs.error {
            AinkradEmptyState(icon: "exclamationmark.triangle", title: "Could not read logs",
                              message: error)
        } else if logs.isLoading && logs.buffer.count == 0 {
            AinkradLoadingState(label: "Reading logs…")
        } else if logs.buffer.count == 0 {
            AinkradEmptyState(icon: "text.alignleft", title: "No output",
                              message: selectedStack == nil
                                  ? "Choose a stack to tail."
                                  : "\(selectedStack?.displayName ?? "") has written nothing yet.")
        } else {
            ThrallLogTextView(lines: logs.visibleLines,
                              palette: ThrallANSIPalette(theme: theme,
                                                          statusColors: statusColors),
                              foreground: theme.foreground,
                              showsServicePrefix: logs.showsServicePrefix,
                              isFollowing: logs.isFollowing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedStack: ThrallStack? {
        selected.flatMap { model.world.stack($0) }
    }

    private var lineSummary: String {
        let shown = logs.visibleLines.count
        let total = logs.buffer.count
        var text = shown == total ? "\(total) lines" : "\(shown) of \(total) lines"
        if logs.buffer.droppedLines > 0 {
            // Said out loud: a tail that silently discards the beginning
            // looks like a log that starts in the middle for no reason.
            text += "  ·  \(logs.buffer.droppedLines) older dropped"
        }
        return text
    }

    private func load() async {
        guard let stack = selectedStack else {
            logs.tail(containers: [], read: { _ in [] })
            return
        }
        let containers = stack.services.flatMap { service in
            service.containers.map { (id: $0.id, service: service.name) }
        }
        await model.tailLogs(containers, into: logs)
    }
}
