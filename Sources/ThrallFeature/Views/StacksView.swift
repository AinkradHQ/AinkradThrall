import AinkradAppKit
import SwiftUI

/// The stacks list: one flat, lazy column of rows.
struct StacksView: View {
    @ObservedObject var model: ThrallViewModel

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.state {
            case .idle,
                .loading where model.world.stacks.isEmpty:
                AinkradLoadingState(label: "Reading the engine…")
            case .failed(let message) where model.world.stacks.isEmpty:
                AinkradErrorState(message: "No engine\n\(message)")
            default:
                if model.world.stacks.isEmpty {
                    AinkradEmptyState(
                        icon: "square.stack.3d.up.slash",
                        title: "Nothing running",
                        message: "No compose project or container was found on "
                            + "\(model.engineLabel).")
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            // Flat rows, so the laziness is real — see `ThrallRow`.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    rowView(row)
                }
            }
            .padding(.vertical, AinkradSpacing.sm)
        }
    }

    @ViewBuilder
    private func rowView(_ row: ThrallRow) -> some View {
        switch row {
        case .stack(let stack):
            StackRow(
                stack: stack,
                isExpanded: model.expandedStacks.contains(stack.id),
                isSelected: model.selectedStack == stack.id,
                isBusy: model.busyStacks.contains(stack.id),
                actions: model.actions(for: stack),
                onAction: { model.perform($0, on: stack) },
                onTap: {
                    model.selectedStack = stack.id
                    model.toggle(stack: stack.id)
                })
        case .service(let stackID, let service):
            ServiceRow(
                service: service,
                isExpanded: model.isExpanded(service: service.name, in: stackID),
                onTap: { model.toggle(service: service.name, in: stackID) })
        case .container(_, _, let container):
            ContainerRow(container: container)
        }
    }
}

/// A stack row. Hover reveals its actions **without moving anything**: the
/// cluster occupies its space at rest and only changes opacity. With 15
/// containers flapping, a row that resizes on hover or on a state change makes
/// the list unusable.
private struct StackRow: View {
    let stack: ThrallStack
    let isExpanded: Bool
    let isSelected: Bool
    let isBusy: Bool
    let actions: [ThrallStackAction]
    let onAction: (ThrallStackAction) -> Void
    let onTap: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        AinkradListRow(
            isSelected: isSelected,
            onTap: onTap,
            leading: {
                HStack(spacing: AinkradSpacing.sm) {
                    // Rotation only — a chevron that swaps glyphs changes
                    // metrics and nudges the title.
                    Image(systemName: "chevron.right")
                        .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isExpanded)
                        .frame(width: skin.size.s10)
                        .foregroundStyle(skin.color(skin.text.muted))
                    AinkradIconGlyph(
                        systemName: stack.isConfigMissing
                            ? "square.stack.3d.up.trianglebadge.exclamationmark"
                            : "square.stack.3d.up")
                }
            },
            title: stack.displayName,
            subtitle: subtitle,
            trailing: {
                // `.fixedSize()` on the badges and priority on the whole
                // cluster are both load-bearing, not tidying. `AinkradListRow`
                // line-limits neither title nor subtitle and gives `trailing`
                // no layout priority, so in the overlay's narrow width a long
                // working-directory path makes the text column claim the row
                // and starves this side. A starved `AinkradBadge` does not
                // clip — it wraps "No compose file" one character per line and
                // draws as a ~8pt-wide, ~230pt-tall stripe, which drags the
                // whole row to that height. Seen on both `compose` stacks,
                // which are exactly the config-missing ones.
                HStack(spacing: AinkradSpacing.md) {
                    if stack.isConfigMissing {
                        AinkradBadge(text: "No compose file", status: .warning)
                            .fixedSize()
                    } else if stack.isStaleRelativeToConfig {
                        AinkradBadge(text: "Config changed", status: .warning)
                            .fixedSize()
                    }
                    AinkradStackedStatusBar(runs: statusRuns(for: stack.breakdown))
                        .frame(width: skin.size.s64)
                    Text("\(stack.containerCount)")
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", weight: "medium", monospacedDigits: true)))
                        .foregroundStyle(theme.foreground.opacity(skin.opacity.o60))
                        .frame(width: skin.size.s22, alignment: .trailing)
                    actionCluster
                }
                .layoutPriority(1)
            }
        )
        .onHover { hovering = $0 }
    }

    /// Present at rest, invisible until hover. Reserving the space is the whole
    /// point: `.opacity` cannot shift a layout, `if hovering` can.
    ///
    /// While a verb is in flight the cluster stays visible and shows a spinner
    /// **in the same footprint**, so a row does not resize the moment the user
    /// clicks it.
    private var actionCluster: some View {
        HStack(spacing: AinkradSpacing.xs) {
            if isBusy {
                AinkradSpinner(size: skin.size.s14)
                    .frame(
                        width: skin.size.s22 * CGFloat(actions.count)
                            + AinkradSpacing.xs * CGFloat(max(0, actions.count - 1)),
                        height: skin.size.s22)
            } else {
                ForEach(actions) { action in
                    AinkradIconButton(
                        systemName: action.icon, size: skin.size.s22,
                        tooltip: action.title
                    ) {
                        onAction(action)
                    }
                }
            }
        }
        .opacity(hovering || isBusy ? 1 : 0)
        .animation(reduceMotion ? nil : AinkradMotion.hover, value: hovering)
        // Not focusable while invisible, or tabbing would land on a hidden
        // control.
        .allowsHitTesting(hovering && !isBusy)
    }

    /// Kept to one line. A wrapped subtitle makes this row taller than its
    /// neighbours, and a list whose row heights depend on how long a path
    /// happens to be is the same defect as a list that reorders.
    ///
    /// The count leads. `AinkradListRow` truncates the subtitle's tail, so
    /// with the path first a long working directory cost the reader the one
    /// number the row exists to show — "…/wt-1058 · 24 servi…".
    private var subtitle: String? {
        let services = stack.services.count
        var parts = [services == 1 ? "1 service" : "\(services) services"]
        if let directory = stack.workingDirectoryDisplay {
            parts.append(ThrallPathDisplay.abbreviate(directory))
        }
        return parts.joined(separator: "  ·  ")
    }
}

private struct ServiceRow: View {
    let service: ThrallService
    let isExpanded: Bool
    let onTap: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        AinkradListRow(
            onTap: service.containers.isEmpty ? nil : onTap,
            leading: {
                HStack(spacing: AinkradSpacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(skin.font(AinkradFontToken(sizeKey: "t9", weight: "semibold")))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isExpanded)
                        .frame(width: skin.size.s9)
                        .foregroundStyle(
                            theme.foreground
                                .opacity(service.containers.isEmpty ? 0 : skin.opacity.o45))
                    AinkradIconGlyph(
                        systemName: "shippingbox",
                        size: 13)  // design-lint: allow frame-literal token-gap size.s13
                }
                .padding(.leading, AinkradSpacing.lg)
            },
            title: service.name,
            subtitle: subtitle,
            trailing: {
                if let state = service.worstState {
                    AinkradBadge(text: state.label, status: state.status)
                } else {
                    // Declared on disk with no container: the row that makes a
                    // fully-down stack legible.
                    AinkradBadge(text: "Not created", status: .neutral)
                }
            })
    }

    private var subtitle: String? {
        ThrallPathDisplay.dependencySummary(service.dependsOn)
    }
}

private struct ContainerRow: View {
    let container: ThrallContainer

    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        AinkradListRow(
            leading: {
                AinkradIconGlyph(systemName: "cube", size: skin.size.s12)
                    .padding(.leading, AinkradSpacing.xl + AinkradSpacing.sm)
            },
            title: container.name,
            // The engine's own prose. Parsing an exit code out of it would be
            // a localisation bug; `inspect` gives the number.
            subtitle: container.statusText,
            trailing: {
                Text(container.image)
                    .font(skin.font(AinkradFontToken(sizeKey: "t10", mono: "system")))
                    .foregroundStyle(skin.color(skin.text.faint))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: skin.size.s220, alignment: .trailing)
            })
    }
}

/// Maps `ThrallStateBreakdown` counts to `[AinkradStatusRun]` for `AinkradStackedStatusBar`.
func statusRuns(for breakdown: ThrallStateBreakdown) -> [AinkradStatusRun] {
    [
        AinkradStatusRun(count: breakdown.running, status: ThrallContainerState.running.status),
        AinkradStatusRun(count: breakdown.created, status: ThrallContainerState.created.status),
        AinkradStatusRun(count: breakdown.paused, status: ThrallContainerState.paused.status),
        AinkradStatusRun(count: breakdown.other, status: ThrallContainerState.removing.status),
        AinkradStatusRun(count: breakdown.exited, status: ThrallContainerState.exited.status),
        AinkradStatusRun(count: breakdown.restarting, status: ThrallContainerState.restarting.status),
        AinkradStatusRun(count: breakdown.dead, status: ThrallContainerState.dead.status),
    ].filter { $0.count > 0 }
}
