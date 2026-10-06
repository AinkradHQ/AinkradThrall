import AinkradAppKit
import SwiftUI

/// The flat container list, and Task R's engine panel.
///
/// **The escape hatch.** The stacks list is the primary surface, but two
/// containers here belong to no compose project at all — and when something is
/// missing, "show me every container and every network on this daemon" is the
/// only question that settles it.
struct ContainersView: View {
    @ObservedObject var model: ThrallViewModel
    @ObservedObject var storage: ThrallStorageModel

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @State private var filter = ""

    private struct Row: Identifiable {
        let id: String
        let name: String
        let stack: String
        let service: String
        let state: ThrallContainerState
        let image: String
    }

    private var rows: [Row] {
        let all = model.world.stacks.flatMap { stack in
            stack.services.flatMap { service in
                service.containers.map {
                    Row(
                        id: $0.id, name: $0.name,
                        stack: stack.displayName, service: service.name,
                        state: $0.state, image: $0.image)
                }
            }
        }
        guard !filter.isEmpty else { return all.sorted { $0.name < $1.name } }
        let needle = filter.lowercased()
        return all.filter {
            $0.name.lowercased().contains(needle) || $0.image.lowercased().contains(needle)
                || $0.stack.lowercased().contains(needle)
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AinkradSpacing.md) {
                    RunCommandCard(model: model)
                    enginePanel
                    networksCard
                    containerTable
                }
                .padding(AinkradSpacing.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await storage.load(client: model.engineClient) }
    }

    private var header: some View {
        HStack(spacing: AinkradSpacing.md) {
            AinkradSearchField(text: $filter, placeholder: "Filter containers")
                .frame(maxWidth: 280)
            Spacer(minLength: 0)
            Text("\(rows.count) containers")
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .foregroundStyle(theme.foreground.opacity(skin.opacity.o50))
        }
        .padding(.horizontal, AinkradSpacing.lg)
        .padding(.vertical, AinkradSpacing.sm)
        .background(theme.surface.opacity(skin.opacity.o25))
    }

    /// Task R's engine panel. **Reachability is shown per context, live**,
    /// because a configured context whose socket is absent is the normal case
    /// — `desktop-linux` is exactly that here — and "why can I not see my
    /// containers" is otherwise unanswerable.
    private var enginePanel: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                Text("Engines").font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
                ForEach(model.contexts) { context in
                    AinkradListRow(
                        leading: {
                            Circle()
                                .fill(indicator(for: context))
                                .frame(width: 6, height: 6)
                        },
                        title: context.name,
                        trailing: {
                            HStack(spacing: AinkradSpacing.sm) {
                                if context.name == model.activeContext?.name {
                                    AinkradBadge(text: "active", status: .success)
                                }
                                if !context.isSupported {
                                    AinkradBadge(text: "unsupported", status: .neutral)
                                } else if !isReachable(context) {
                                    AinkradBadge(text: "not running", status: .warning)
                                }
                                Text(
                                    ThrallPathDisplay.abbreviate(
                                        context.endpoint.displayString,
                                        maxLength: 40)
                                )
                                .font(skin.font(AinkradFontToken(sizeKey: "t10", mono: "system")))
                                .foregroundStyle(skin.color(skin.text.faint))
                            }
                        })
                }
                // The finding that made `engineKey` exist: two contexts can be
                // the same daemon, and saying so stops a false "my container
                // vanished".
                if let duplicate = duplicateEngineNote {
                    AinkradCaption(duplicate)
                }
                ForEach(model.contextNotes, id: \.self) { note in
                    AinkradCaption(note)
                }
            }
        }
    }

    /// Nil unless two listed contexts resolve to the same socket.
    private var duplicateEngineNote: String? {
        var byKey: [String: [String]] = [:]
        for context in model.contexts where context.isSupported {
            byKey[context.endpoint.engineKey, default: []].append(context.name)
        }
        guard let shared = byKey.values.first(where: { $0.count > 1 }) else { return nil }
        return "\(shared.joined(separator: " and ")) are the same daemon — their socket paths "
            + "differ but resolve to one file."
    }

    /// A filesystem check, which is all "is this engine running" means for a
    /// unix socket. Cheap enough to do on render; a connect attempt per
    /// context per frame would not be.
    private func isReachable(_ context: ThrallEngineContext) -> Bool {
        guard case .unixSocket(let path) = context.endpoint else { return false }
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }

    private func indicator(for context: ThrallEngineContext) -> Color {
        if !context.isSupported { return theme.foreground.opacity(skin.opacity.o25) }
        if context.name == model.activeContext?.name { return theme.accentPrimary }
        return isReachable(context) ? theme.foreground.opacity(skin.opacity.o50) : .orange
    }

    private var networksCard: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                Text("Networks — \(storage.networks.count)")
                    .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
                ForEach(storage.networks, id: \.id) { network in
                    AinkradListRow(
                        leading: { EmptyView() },
                        title: network.name,
                        trailing: {
                            HStack(spacing: AinkradSpacing.sm) {
                                if let project = network.composeProject {
                                    AinkradBadge(text: project, status: .neutral)
                                }
                                if network.internalOnly {
                                    AinkradBadge(text: "internal", status: .neutral)
                                }
                                Text(network.driver)
                                    .font(skin.font(AinkradFontToken(sizeKey: "t10", mono: "system")))
                                    .foregroundStyle(skin.color(skin.text.faint))
                            }
                        })
                }
            }
        }
    }

    private var containerTable: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            Text("Every container")
                .font(skin.font(AinkradFontToken(sizeKey: "t12", weight: "semibold")))
            // Lazy, and one row per container: 48 rows is fine here where 135
            // volume rows were not, and the filter keeps it smaller in practice.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    AinkradListRow(
                        leading: { AinkradIconGlyph(systemName: "cube", size: 12) },
                        title: row.name,
                        subtitle: "\(row.stack) · \(row.service) · \(row.image)",
                        trailing: {
                            AinkradBadge(
                                text: row.state.label, status: row.state.status)
                        })
                }
            }
        }
    }
}
