import SwiftUI
import AinkradAppKit

/// The stacks list: one flat, lazy column of rows.
struct StacksView: View {
    @ObservedObject var model: ThrallViewModel

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading where model.world.stacks.isEmpty:
                AinkradLoadingState(label: "Reading the engine…")
            case .failed(let message) where model.world.stacks.isEmpty:
                AinkradEmptyState(icon: "bolt.horizontal.circle",
                                  title: "No engine",
                                  message: message)
            default:
                if model.world.stacks.isEmpty {
                    AinkradEmptyState(icon: "square.stack.3d.up.slash",
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
            StackRow(stack: stack,
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
            ServiceRow(service: service,
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
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isExpanded)
                        .frame(width: 10)
                        .foregroundStyle(theme.foreground.opacity(0.55))
                    AinkradIconGlyph(systemName: stack.isConfigMissing
                        ? "square.stack.3d.up.trianglebadge.exclamationmark"
                        : "square.stack.3d.up")
                }
            },
            title: stack.displayName,
            subtitle: subtitle,
            trailing: {
                HStack(spacing: AinkradSpacing.md) {
                    if stack.isConfigMissing {
                        AinkradBadge(text: "No compose file", status: .warning)
                    } else if stack.isStaleRelativeToConfig {
                        AinkradBadge(text: "Config changed", status: .warning)
                    }
                    StateRibbon(breakdown: stack.breakdown)
                    Text("\(stack.containerCount)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.foreground.opacity(0.6))
                        .frame(width: 22, alignment: .trailing)
                    actionCluster
                }
            })
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
                AinkradSpinner(size: 14)
                    .frame(width: 22 * CGFloat(actions.count)
                           + AinkradSpacing.xs * CGFloat(max(0, actions.count - 1)),
                           height: 22)
            } else {
                ForEach(actions) { action in
                    AinkradIconButton(systemName: action.icon, size: 22,
                                      tooltip: action.title) {
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
    private var subtitle: String? {
        var parts: [String] = []
        if let directory = stack.workingDirectoryDisplay {
            parts.append(ThrallPathDisplay.abbreviate(directory))
        }
        let services = stack.services.count
        parts.append(services == 1 ? "1 service" : "\(services) services")
        return parts.joined(separator: "  ·  ")
    }
}

private struct ServiceRow: View {
    let service: ThrallService
    let isExpanded: Bool
    let onTap: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        AinkradListRow(
            onTap: service.containers.isEmpty ? nil : onTap,
            leading: {
                HStack(spacing: AinkradSpacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : AinkradMotion.hover, value: isExpanded)
                        .frame(width: 9)
                        .foregroundStyle(theme.foreground
                            .opacity(service.containers.isEmpty ? 0 : 0.45))
                    AinkradIconGlyph(systemName: "shippingbox", size: 13)
                }
                .padding(.leading, AinkradSpacing.lg)
            },
            title: service.name,
            subtitle: subtitle,
            trailing: {
                if let state = service.worstState {
                    AinkradBadge(text: state.label, status: status(for: state))
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

    private func status(for state: ThrallContainerState) -> AinkradStatus {
        switch state {
        case .running: return .success
        case .restarting, .dead: return .danger
        case .exited, .unknown: return .warning
        default: return .neutral
        }
    }
}

private struct ContainerRow: View {
    let container: ThrallContainer

    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        AinkradListRow(
            leading: {
                AinkradIconGlyph(systemName: "cube", size: 12)
                    .padding(.leading, AinkradSpacing.xl + AinkradSpacing.sm)
            },
            title: container.name,
            // The engine's own prose. Parsing an exit code out of it would be
            // a localisation bug; `inspect` gives the number.
            subtitle: container.statusText,
            trailing: {
                Text(container.image)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(theme.foreground.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
            })
    }
}
