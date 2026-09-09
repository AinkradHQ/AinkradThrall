import SwiftUI
import AinkradAppKit

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
    @State private var filter = ""

    private struct Row: Identifiable {
        let id: String
        let name: String
        let stack: String
        let service: String
        let state: String
        let image: String
    }

    private var rows: [Row] {
        let all = model.world.stacks.flatMap { stack in
            stack.services.flatMap { service in
                service.containers.map {
                    Row(id: $0.id, name: $0.name,
                        stack: stack.displayName, service: service.name,
                        state: $0.state.label, image: $0.image)
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
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.foreground.opacity(0.5))
        }
        .padding(.horizontal, AinkradSpacing.lg)
        .padding(.vertical, AinkradSpacing.sm)
        .background(theme.surface.opacity(0.25))
    }

    /// Task R's engine panel. **Reachability is shown per context, live**,
    /// because a configured context whose socket is absent is the normal case
    /// — `desktop-linux` is exactly that here — and "why can I not see my
    /// containers" is otherwise unanswerable.
    private var enginePanel: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                Text("Engines").font(.system(size: 13, weight: .semibold))
                ForEach(model.contexts) { context in
                    HStack(spacing: AinkradSpacing.sm) {
                        Circle()
                            .fill(indicator(for: context))
                            .frame(width: 6, height: 6)
                        Text(context.name).font(.system(size: 11, weight: .medium))
                        if context.name == model.activeContext?.name {
                            AinkradBadge(text: "active", status: .success)
                        }
                        if !context.isSupported {
                            AinkradBadge(text: "unsupported", status: .neutral)
                        } else if !isReachable(context) {
                            AinkradBadge(text: "not running", status: .warning)
                        }
                        Spacer(minLength: 0)
                        Text(ThrallPathDisplay.abbreviate(context.endpoint.displayString,
                                                           maxLength: 40))
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(theme.foreground.opacity(0.45))
                    }
                }
                // The finding that made `engineKey` exist: two contexts can be
                // the same daemon, and saying so stops a false "my container
                // vanished".
                if let duplicate = duplicateEngineNote {
                    Text(duplicate)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.foreground.opacity(0.5))
                }
                ForEach(model.contextNotes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.foreground.opacity(0.5))
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
        if !context.isSupported { return theme.foreground.opacity(0.25) }
        if context.name == model.activeContext?.name { return theme.accentPrimary }
        return isReachable(context) ? theme.foreground.opacity(0.5) : .orange
    }

    private var networksCard: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                Text("Networks — \(storage.networks.count)")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(storage.networks, id: \.id) { network in
                    HStack(spacing: AinkradSpacing.sm) {
                        Text(network.name).font(.system(size: 11))
                        if let project = network.composeProject {
                            AinkradBadge(text: project, status: .neutral)
                        }
                        if network.internalOnly {
                            AinkradBadge(text: "internal", status: .neutral)
                        }
                        Spacer(minLength: 0)
                        Text(network.driver)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(theme.foreground.opacity(0.45))
                    }
                }
            }
        }
    }

    private var containerTable: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            Text("Every container")
                .font(.system(size: 12, weight: .semibold))
            // Lazy, and one row per container: 48 rows is fine here where 135
            // volume rows were not, and the filter keeps it smaller in practice.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    AinkradListRow(
                        leading: { AinkradIconGlyph(systemName: "cube", size: 12) },
                        title: row.name,
                        subtitle: "\(row.stack) · \(row.service) · \(row.image)",
                        trailing: {
                            AinkradBadge(text: row.state,
                                         status: row.state == "Running" ? .success : .warning)
                        })
                }
            }
        }
    }
}
