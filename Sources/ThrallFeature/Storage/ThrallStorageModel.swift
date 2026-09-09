import Foundation
import AinkradAppKit

/// Backs the Images, Storage and Networks areas.
///
/// **Loaded on demand, never on the reconcile loop.** `/system/df` costs
/// 1.86 s against <=0.2 s for every other read on the reference machine — it
/// walks 289 build-cache entries and 135 volumes to get there. So this model
/// fetches once when its area is opened, caches, and refreshes only when asked.
@MainActor
public final class ThrallStorageModel: ObservableObject {
    @Published public private(set) var usage: ThrallDiskUsageDTO?
    @Published public private(set) var networks: [ThrallNetworkDTO] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public private(set) var loadedAt: Date?
    /// The last reclaim outcome, shown as a toast.
    @Published public var lastReclaim: String?

    // Reclaim opt-ins, all defaulting **off** for volumes.
    @Published public var includeImages = true
    @Published public var includeBuildCache = true
    /// **Off by default, deliberately.** Volumes are the only irreversible
    /// part of a reclaim, so including them is an explicit act.
    @Published public var includeVolumes = false

    /// Targets the user has deselected. Absence means selected, so a newly
    /// appearing target is included rather than silently skipped.
    @Published public var excluded: Set<String> = []

    public init() {}

    /// Injects a snapshot without a daemon. Test-only, and named so it cannot
    /// be mistaken for a real load path.
    func applyForTesting(usage: ThrallDiskUsageDTO) {
        self.usage = usage
        loadedAt = Date()
    }

    public var plan: ThrallReclaimPlan {
        guard let usage else { return ThrallReclaimPlan(targets: []) }
        let full = ThrallReclaimPlan.make(from: usage,
                                          includeVolumes: includeVolumes,
                                          includeImages: includeImages,
                                          includeBuildCache: includeBuildCache)
        return ThrallReclaimPlan(targets: full.targets.filter { !excluded.contains($0.id) })
    }

    /// Volumes grouped by owning compose project.
    ///
    /// **135 rows must never hit an eager table** — `AinkradDataTable` is a
    /// `VStack` + `ForEach`, so it materialises every row. Grouping into
    /// collapsed disclosure groups is what keeps the area openable, and the
    /// `UNOWNED` group is the interesting one: 93 of the 135 volumes here have
    /// no owner and account for 7.3 GB.
    public var volumeGroups: [(owner: String, volumes: [ThrallVolumeDTO], bytes: Int64)] {
        guard let usage else { return [] }
        var buckets: [String: [ThrallVolumeDTO]] = [:]
        for volume in usage.volumes {
            buckets[volume.composeProject ?? Self.unownedGroup, default: []].append(volume)
        }
        return buckets
            .map { (owner: $0.key,
                    volumes: $0.value.sorted { ($0.usage?.size ?? 0) > ($1.usage?.size ?? 0) },
                    bytes: $0.value.reduce(0) { $0 + max(0, $1.usage?.size ?? 0) }) }
            // Unowned last: it is the biggest and the least identifiable, so
            // leading with it buries the groups a user can actually recognise.
            .sorted { left, right in
                if (left.owner == Self.unownedGroup) != (right.owner == Self.unownedGroup) {
                    return right.owner == Self.unownedGroup
                }
                return left.owner < right.owner
            }
    }

    public static let unownedGroup = "UNOWNED / DANGLING"

    public var images: [ThrallImageDTO] { usage?.images ?? [] }

    public func load(client: ThrallEngineClient?, force: Bool = false) async {
        guard let client else { return }
        // The 1.86 s cost is why this guard exists.
        if usage != nil, !force { return }
        isLoading = true
        error = nil
        do {
            usage = try await client.diskUsage()
            networks = try await client.networks()
            loadedAt = Date()
        } catch let engineError as ThrallEngineError {
            // Shadowing: the `catch`'s own binding is named `error` too, which
            // is the published property's name.
            self.error = ThrallViewModel.describe(engineError)
        } catch {
            self.error = "\(error)"
        }
        isLoading = false
    }

    /// Removes each target **by its exact id**, one call at a time.
    ///
    /// Never a prune with an empty filter. One failure does not abandon the
    /// rest — a half-finished reclaim is worse than either outcome — and the
    /// summary reports what actually happened rather than what was planned.
    public func reclaim(_ plan: ThrallReclaimPlan, client: ThrallEngineClient?) async {
        guard let client, !plan.isEmpty else { return }
        isLoading = true
        var removed = 0
        var freed: Int64 = 0
        var failures: [String] = []

        for target in plan.targets {
            do {
                switch target.kind {
                case .image: try await client.removeImage(id: target.identifier)
                case .volume: try await client.removeVolume(name: target.identifier)
                case .network: try await client.removeNetwork(id: target.identifier)
                case .buildCache: continue
                }
                removed += 1
                freed += target.bytes
            } catch {
                failures.append("\(target.displayName): \(error)")
            }
        }
        // Build cache in one call, with the exact ids as a filter — the engine
        // has no per-record delete.
        let cacheIDs = plan.targets(of: .buildCache).map(\.identifier)
        if !cacheIDs.isEmpty {
            do {
                freed += try await client.pruneBuildCache(ids: cacheIDs)
                removed += cacheIDs.count
            } catch {
                failures.append("build cache: \(error)")
            }
        }

        lastReclaim = failures.isEmpty
            ? "Removed \(removed) items, freed \(ThrallReclaimPlan.humanBytes(freed))."
            : "Removed \(removed), freed \(ThrallReclaimPlan.humanBytes(freed)); "
                + "\(failures.count) failed. \(failures.prefix(2).joined(separator: "; "))"
        isLoading = false
        await load(client: client, force: true)
    }
}
