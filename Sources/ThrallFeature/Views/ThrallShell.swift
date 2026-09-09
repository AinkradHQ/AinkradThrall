import SwiftUI
import AinkradAppKit

/// The shell: a top bar carrying the engine chip, a rail on the left, content
/// on the right, and **no separator line** anywhere. Surfaces are
/// distinguished by fill, never by a rule — the house rule is that it should
/// look like an OS, not a web app.
public struct ThrallShell: View {
    private let host: HostServices
    @ObservedObject private var model: ThrallViewModel
    /// Observed **separately** from `model`. A nested `ObservableObject` does
    /// not propagate its changes to a parent's observer, so with only `model`
    /// observed the rail's incident badge never appeared — the count changed
    /// and nothing invalidated this body. Caught by screenshot.
    @ObservedObject private var triage: ThrallTriageModel
    @ObservedObject private var settings: ThrallSettingsStore
    @State private var area: NavArea = .stacks
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @Environment(\.ainkradToastCenter) private var toasts

    public init(host: HostServices) {
        self.host = host
        let model = ThrallRuntime.viewModel(for: host)
        self.model = model
        self.triage = model.triage
        self.settings = ThrallRuntime.settingsStore(for: host)
    }

    private var tokens: HostThemeTokens { host.theme.tokens }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                rail
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background)
        .foregroundStyle(tokens.foreground)
        .ainkradHostTheme(host.theme)
        .task {
            model.bootstrap()
            model.startPolling()
        }
        // Down is the only verb that destroys state, so it is the only one
        // that asks. Restart is unconfirmed on purpose: the service is already
        // broken and restart is idempotent.
        .ainkradConfirmDialog(
            isPresented: Binding(get: { model.pendingDown != nil },
                                 set: { if !$0 { model.pendingDown = nil } }),
            title: "Take \(model.pendingDown?.displayName ?? "") down?",
            message: downMessage,
            confirmTitle: "Down",
            isDestructive: true,
            onConfirm: { model.confirmPendingDown() })
        // The kit's toast host is mounted once at the root, and messages are
        // pushed into `\.ainkradToastCenter` — the shared queue every Ainkrad
        // surface uses, rather than a local banner of Thrall's own.
        .ainkradConfirmDialog(
            isPresented: Binding(get: { model.pendingTeardown != nil },
                                 set: { if !$0 { model.pendingTeardown = nil } }),
            title: "Tear down \(model.pendingTeardown?.displayName ?? "") by label?",
            message: teardownMessage,
            confirmTitle: "Tear down",
            isDestructive: true,
            onConfirm: { model.confirmPendingTeardown() })
        .ainkradToastHost()
        .onChange(of: model.lastActionMessage) { _, message in
            guard let message else { return }
            toasts.show(message, status: message.contains("failed")
                        || message.contains("Refused") ? .danger : .success)
            model.lastActionMessage = nil
        }
    }

    /// Names the containers, and says explicitly what is **not** removed.
    /// `down` without `--volumes` keeps the data; saying so is what stops the
    /// user hesitating over the one verb they will use most.
    private var downMessage: String {
        guard let stack = model.pendingDown else { return "" }
        let count = stack.containerCount
        return "This stops and removes \(count) container\(count == 1 ? "" : "s") in "
            + "\(stack.displayName). Named volumes are kept — Thrall never removes a volume "
            + "as part of Down."
    }

    /// Says out loud that volumes survive. This is the remedy for a stack that
    /// cannot be reached any other way, so the user needs to know exactly how
    /// far it goes.
    private var teardownMessage: String {
        guard let stack = model.pendingTeardown else { return "" }
        let count = stack.containerCount
        return "\(stack.displayName)'s compose file is gone, so `docker compose down` cannot "
            + "reach it. Thrall will stop and remove its \(count) container"
            + "\(count == 1 ? "" : "s") by matching the compose project label. "
            + "**Volumes are not touched.**"
    }

    // MARK: - Top bar

    /// The engine chip is a **persistent top-bar element, not a nav area**.
    /// With three contexts configured on this machine — two of which name the
    /// same daemon through different paths — "is this the container I think it
    /// is" is a real failure mode, and the answer has to be on screen at all
    /// times rather than one click away.
    private var topBar: some View {
        HStack(spacing: AinkradSpacing.md) {
            Text("Thrall")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tokens.foreground.opacity(0.85))

            engineChip

            if case .failed(let message) = model.state, !model.world.stacks.isEmpty {
                // Stale-but-visible: the last good world stays on screen and
                // the failure is stated, rather than the list emptying itself.
                AinkradBadge(text: message, status: .warning)
            }

            Spacer(minLength: 0)

            summary

            AinkradIconButton(systemName: "arrow.clockwise", size: 24, tooltip: "Refresh") {
                Task { await model.refresh() }
            }
        }
        .padding(.horizontal, AinkradSpacing.lg)
        .padding(.vertical, AinkradSpacing.sm)
        // Same fill as the body: the title bar is continuous with the window.
        .background(tokens.background)
    }

    /// Built with `AinkradMenuButton`, not SwiftUI's `Menu`.
    ///
    /// Two reasons, and the kit's own doc comment states the first: `Menu`
    /// renders a stock AppKit menu — grey, system corner radius, system
    /// highlight — which lands in the middle of an Ainkrad HUD looking like it
    /// belongs to a different application. The second is that macOS collapses
    /// a `Menu`'s label to its first `Text`, so the status dot and the
    /// negotiated API version were being silently dropped from the chip.
    private var engineChip: some View {
        AinkradMenuButton(items: model.contexts.map { context in
            AinkradMenuItem(
                title: context.isSupported ? context.name : "\(context.name) — unavailable",
                systemName: context.isSupported ? "bolt.horizontal" : "bolt.horizontal.circle"
            ) {
                // An unsupported context still appears, and selecting it shows
                // the reason rather than doing nothing — a control that
                // silently ignores a click is worse than one that explains.
                model.select(context)
                Task { await model.refresh() }
            }
        }) {
            HStack(spacing: AinkradSpacing.xs) {
                Circle()
                    .fill(engineIndicator)
                    .frame(width: 6, height: 6)
                Text(model.engineLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.foreground.opacity(0.85))
                if let version = model.engineVersion {
                    Text("API \(version.negotiated.description)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(tokens.foreground.opacity(0.45))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tokens.foreground.opacity(0.4))
            }
            .padding(.horizontal, AinkradSpacing.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: AinkradRadius.sm, style: .continuous)
                    .fill(tokens.foreground.opacity(0.06))
            )
        }
        .fixedSize()
    }

    private var engineIndicator: Color {
        switch model.state {
        case .loaded: return tokens.accentPrimary
        case .failed: return .orange
        case .idle, .loading: return tokens.foreground.opacity(0.35)
        }
    }

    /// Counts for the whole machine. Monospaced digits so the numbers changing
    /// cannot nudge anything beside them.
    private var summary: some View {
        let stacks = model.world.stacks
        let running = stacks.reduce(0) { $0 + $1.breakdown.running }
        let total = stacks.reduce(0) { $0 + $1.containerCount }
        return Text("\(stacks.count) stacks · \(running)/\(total) running")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(tokens.foreground.opacity(0.55))
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(spacing: AinkradSpacing.xs) {
            ForEach(NavArea.built) { item in
                RailItem(area: item,
                         isSelected: item == area,
                         tokens: tokens,
                         // Triage is the only area that carries a badge.
                         badge: item == .triage ? triage.incidents.count : nil,
                         onTap: { area = item })
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, AinkradSpacing.md)
        .padding(.horizontal, AinkradSpacing.sm)
        .frame(width: 56)
        // Fill, not a rule.
        .background(tokens.surface.opacity(0.35))
    }

    @ViewBuilder
    private var content: some View {
        switch area {
        case .stacks:
            StacksView(model: model)
        case .triage:
            TriageView(model: model, triage: triage)
        default:
            AinkradEmptyState(icon: area.icon,
                              title: area.title,
                              message: "Coming in a later milestone.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A rail item. Hover changes **fill and opacity only, never geometry** — a
/// rail that grows on hover pushes every item below it.
private struct RailItem: View {
    let area: NavArea
    let isSelected: Bool
    let tokens: HostThemeTokens
    let badge: Int?
    let onTap: () -> Void

    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: area.icon)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 40, height: 34)
                .foregroundStyle(isSelected
                                 ? tokens.accentPrimary
                                 : tokens.foreground.opacity(hovering ? 0.9 : 0.55))
                .background(
                    RoundedRectangle(cornerRadius: AinkradRadius.sm, style: .continuous)
                        .fill(tokens.foreground.opacity(isSelected ? 0.10
                                                        : (hovering ? 0.06 : 0)))
                )
                // Inside the fixed 40x34 frame, so a count appearing or
                // changing width cannot move the rail or the items below it.
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                            .offset(x: -1, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(area.title)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : AinkradMotion.hover, value: hovering)
        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isSelected)
    }
}
