import SwiftUI
import AinkradAppKit

/// Tasks P and Q — volumes, build cache and reclaim.
///
/// One area rather than three, because 135 volumes + 289 build-cache entries +
/// 13 unused images is **one story wearing three nouns**: where the 28 GB went.
struct StorageView: View {
    @ObservedObject var model: ThrallViewModel
    @ObservedObject var storage: ThrallStorageModel

    @Environment(\.ainkradTheme) private var theme
    @State private var expandedGroups: Set<String> = []
    @State private var confirmingReclaim = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = storage.error {
                AinkradEmptyState(icon: "exclamationmark.triangle",
                                  title: "Could not read storage", message: error)
            } else if storage.usage == nil {
                AinkradLoadingState(label: "Reading storage… (system/df takes a moment)")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.md) {
                        totals
                        reclaimCard
                        volumeGroups
                    }
                    .padding(AinkradSpacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await storage.load(client: model.engineClient) }
        .ainkradConfirmDialog(
            isPresented: $confirmingReclaim,
            title: "Remove \(storage.plan.targets.count) items?",
            message: storage.plan.confirmation(),
            confirmTitle: "Remove",
            isDestructive: true,
            onConfirm: {
                let plan = storage.plan
                Task { await storage.reclaim(plan, client: model.engineClient) }
            })
    }

    private var header: some View {
        HStack(spacing: AinkradSpacing.md) {
            Text("Storage").font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            if storage.isLoading { AinkradSpinner(size: 14) }
            AinkradIconButton(systemName: "arrow.clockwise", size: 24, tooltip: "Reload") {
                Task { await storage.load(client: model.engineClient, force: true) }
            }
        }
        .padding(.horizontal, AinkradSpacing.lg)
        .padding(.vertical, AinkradSpacing.sm)
        .background(theme.surface.opacity(0.25))
    }

    private var totals: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                let usage = storage.usage
                AinkradStatRow(label: "Image layers",
                               value: ThrallReclaimPlan.humanBytes(usage?.layersSize ?? 0))
                AinkradStatRow(label: "Volumes",
                               value: "\(usage?.volumes.count ?? 0) · "
                                   + ThrallReclaimPlan.humanBytes(
                                       usage?.volumes.reduce(0) {
                                           $0 + max(0, $1.usage?.size ?? 0) } ?? 0))
                AinkradStatRow(label: "Unused volumes",
                               value: ThrallReclaimPlan.humanBytes(
                                   usage?.reclaimableVolumes ?? 0),
                               status: .warning)
                AinkradStatRow(label: "Build cache",
                               value: "\(usage?.buildCache.count ?? 0) entries · "
                                   + ThrallReclaimPlan.humanBytes(
                                       usage?.reclaimableBuildCache ?? 0),
                               status: .warning)
            }
        }
    }

    /// **The no-prune contract, on screen.** The target set is enumerated by
    /// name before anything is removed, and removal is by explicit id.
    private var reclaimCard: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                Text("Reclaim")
                    .font(.system(size: 13, weight: .semibold))
                Text("Thrall never runs `prune`. It lists exactly what it will remove, then "
                     + "removes each item by its own id.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foreground.opacity(0.6))

                AinkradCheckbox(isOn: $storage.includeImages,
                                label: "Unused images")
                AinkradCheckbox(isOn: $storage.includeBuildCache,
                                label: "Build cache not in use")
                // Off by default and labelled as the irreversible one.
                AinkradCheckbox(isOn: $storage.includeVolumes,
                                label: "Unused volumes — cannot be undone")

                let plan = storage.plan
                if plan.isEmpty {
                    Text("Nothing selected.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foreground.opacity(0.45))
                } else {
                    Text("\(plan.targets.count) items · "
                         + ThrallReclaimPlan.humanBytes(plan.totalBytes))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                    // Enumerated by name. The list is the safety mechanism, so
                    // it is not collapsed behind a disclosure.
                    ForEach(plan.targets.prefix(12)) { target in
                        HStack(spacing: AinkradSpacing.sm) {
                            AinkradBadge(text: target.kind.rawValue,
                                         status: target.kind == .volume ? .danger : .neutral)
                            Text(target.displayName)
                                .font(.system(size: 10).monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(ThrallReclaimPlan.humanBytes(target.bytes))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(theme.foreground.opacity(0.5))
                            AinkradIconButton(systemName: "minus.circle", size: 20,
                                              tooltip: "Leave this one alone") {
                                storage.excluded.insert(target.id)
                            }
                        }
                    }
                    if plan.targets.count > 12 {
                        Text("… and \(plan.targets.count - 12) more, all listed in the "
                             + "confirmation before anything is removed.")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.foreground.opacity(0.45))
                    }
                    AinkradButton(title: "Remove these", style: .danger) {
                        confirmingReclaim = true
                    }
                }
            }
        }
    }

    /// **Grouped and collapsed**, because 135 rows must never hit
    /// `AinkradDataTable` — it is a `VStack` + `ForEach` and materialises every
    /// row. The `UNOWNED` group is the interesting one: 93 volumes, 7.3 GB.
    private var volumeGroups: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            Text("Volumes by owner")
                .font(.system(size: 12, weight: .semibold))
            ForEach(storage.volumeGroups, id: \.owner) { group in
                AinkradDisclosureGroup(
                    title: "\(group.owner) — \(group.volumes.count) · "
                        + ThrallReclaimPlan.humanBytes(group.bytes),
                    isExpanded: Binding(
                        get: { expandedGroups.contains(group.owner) },
                        set: { expanded in
                            if expanded { expandedGroups.insert(group.owner) }
                            else { expandedGroups.remove(group.owner) }
                        }),
                    hitCount: group.volumes.filter { ($0.usage?.refCount ?? -1) == 0 }.count
                ) {
                    // Only the expanded group's rows are built, which is the
                    // whole point of the grouping.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group.volumes, id: \.name) { volume in
                            HStack(spacing: AinkradSpacing.sm) {
                                Text(volume.name)
                                    .font(.system(size: 10).monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if (volume.usage?.refCount ?? -1) == 0 {
                                    AinkradBadge(text: "unused", status: .warning)
                                }
                                Spacer(minLength: 0)
                                Text(ThrallReclaimPlan.humanBytes(
                                    max(0, volume.usage?.size ?? 0)))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(theme.foreground.opacity(0.5))
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
    }
}
