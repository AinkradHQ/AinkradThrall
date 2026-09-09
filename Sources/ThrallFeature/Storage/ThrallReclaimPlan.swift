import Foundation

/// Something reclaimable, named.
public struct ThrallReclaimTarget: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case image, volume, buildCache, network
    }

    public let kind: Kind
    /// The **exact** id removal will use. Never re-derived at removal time.
    public let identifier: String
    /// What the user sees. For a volume this is its name, which is the only
    /// thing that lets them recognise their own database.
    public let displayName: String
    public let bytes: Int64
    /// The owning compose project, where one is known.
    public let owner: String?
    /// Why this is considered reclaimable, in the user's words.
    public let reason: String

    /// Kind-prefixed, because an image id and a volume name can collide and a
    /// list that silently drops one row is how the wrong thing gets deleted.
    public var id: String { "\(kind.rawValue):\(identifier)" }

    public init(kind: Kind, identifier: String, displayName: String, bytes: Int64,
                owner: String?, reason: String) {
        self.kind = kind
        self.identifier = identifier
        self.displayName = displayName
        self.bytes = bytes
        self.owner = owner
        self.reason = reason
    }
}

/// A reclaim proposal: an explicit, named list.
///
/// **Thrall never calls a bare `prune`.** Not as a convenience, not behind a
/// confirmation. `docker volume prune` silently eating a database volume is
/// the one unrecoverable mistake this app can make, and 93 of the 135 volumes
/// on the reference machine were unreferenced — precisely the population where
/// it happens. So the flow is fixed:
///
///  1. compute the target set,
///  2. **enumerate it by name on screen**,
///  3. remove by explicit ID, one call per target.
///
/// A prune leaves the daemon to decide what "unused" meant at the moment it
/// ran, which can differ from what the user was shown. Removing by ID cannot.
public struct ThrallReclaimPlan: Equatable, Sendable {
    public let targets: [ThrallReclaimTarget]

    public var totalBytes: Int64 { targets.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { targets.isEmpty }

    public func targets(of kind: ThrallReclaimTarget.Kind) -> [ThrallReclaimTarget] {
        targets.filter { $0.kind == kind }
    }

    public func bytes(of kind: ThrallReclaimTarget.Kind) -> Int64 {
        targets(of: kind).reduce(0) { $0 + $1.bytes }
    }

    /// Builds the plan from a `/system/df` snapshot.
    ///
    /// Deliberately conservative at each step, because the cost of including
    /// something wrongly is unbounded and the cost of missing something is a
    /// few gigabytes.
    public static func make(from usage: ThrallDiskUsageDTO,
                            includeVolumes: Bool,
                            includeImages: Bool,
                            includeBuildCache: Bool) -> ThrallReclaimPlan {
        var targets: [ThrallReclaimTarget] = []

        if includeImages {
            for image in usage.images where image.containers == 0 {
                targets.append(ThrallReclaimTarget(
                    kind: .image,
                    identifier: image.id,
                    displayName: image.repoTags.first ?? String(image.id.prefix(19)),
                    bytes: image.size,
                    owner: nil,
                    reason: image.isDangling
                        ? "untagged and unused by any container"
                        : "not used by any container"))
            }
        }

        if includeVolumes {
            for volume in usage.volumes where (volume.usage?.refCount ?? -1) == 0 {
                targets.append(ThrallReclaimTarget(
                    kind: .volume,
                    identifier: volume.name,
                    displayName: volume.name,
                    bytes: max(0, volume.usage?.size ?? 0),
                    owner: volume.composeProject,
                    // Says what is *not* known: a volume with no container
                    // referencing it may still be the only copy of something.
                    reason: volume.isAnonymous
                        ? "anonymous, no container references it"
                        : "no container references it — check this is not data you want"))
            }
        }

        if includeBuildCache {
            for record in usage.buildCache where !record.inUse {
                targets.append(ThrallReclaimTarget(
                    kind: .buildCache,
                    identifier: record.id,
                    displayName: record.description.isEmpty
                        ? record.id
                        : String(record.description.prefix(80)),
                    bytes: record.size,
                    owner: nil,
                    reason: "build cache, not in use"))
            }
        }

        // Largest first: the user is deciding what to delete, and size is the
        // only reason to delete anything here.
        return ThrallReclaimPlan(targets: targets.sorted { $0.bytes > $1.bytes })
    }

    /// The sentence shown before anything is removed.
    public func confirmation() -> String {
        let volumes = targets(of: .volume)
        var lines = ["Thrall will remove \(targets.count) item"
            + "\(targets.count == 1 ? "" : "s"), freeing about \(Self.humanBytes(totalBytes))."]
        if !volumes.isEmpty {
            // Volumes get their own sentence, always. They are the only
            // irreversible part of this.
            lines.append("")
            lines.append("\(volumes.count) of them are VOLUMES, and volume data cannot be "
                + "recovered: \(volumes.prefix(6).map(\.displayName).joined(separator: ", "))"
                + (volumes.count > 6 ? ", and \(volumes.count - 6) more" : "") + ".")
        }
        lines.append("")
        lines.append("Each is removed by its exact id. Thrall does not run `prune`.")
        return lines.joined(separator: "\n")
    }

    public static func humanBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(Int(value)) \(units[index])"
            : String(format: "%.1f %@", value, units[index])
    }
}
