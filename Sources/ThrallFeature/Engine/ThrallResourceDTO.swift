import Foundation

/// An image as `GET /images/json` describes it.
public struct ThrallImageDTO: Decodable, Equatable, Sendable {
    public let id: String
    public let parentID: String
    public let repoTags: [String]
    public let repoDigests: [String]
    /// Unix seconds.
    public let created: Int
    public let size: Int64
    /// **`-1` means "not computed", not "zero".** This endpoint only computes
    /// shared size when asked (`shared-size=true`), and 13 of the 30 images
    /// here come back `-1`. Summing it as a number produces a negative total.
    public let sharedSize: Int64
    /// How many containers reference it. `0` is the reclaim signal — 13 of 30
    /// here, 3.5 GB.
    public let containers: Int
    public let labels: [String: String]

    /// Nil when the engine did not compute it, so a caller cannot add the
    /// sentinel into a total by accident.
    public var computedSharedSize: Int64? { sharedSize < 0 ? nil : sharedSize }

    /// True for an image with no tag — `<none>:<none>` in `docker images`.
    public var isDangling: Bool { repoTags.isEmpty || repoTags == ["<none>:<none>"] }

    enum CodingKeys: String, CodingKey {
        case id = "Id", parentID = "ParentId", repoTags = "RepoTags"
        case repoDigests = "RepoDigests", created = "Created", size = "Size"
        case sharedSize = "SharedSize", containers = "Containers", labels = "Labels"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        parentID = try values.decodeIfPresent(String.self, forKey: .parentID) ?? ""
        repoTags = try values.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        repoDigests = try values.decodeIfPresent([String].self, forKey: .repoDigests) ?? []
        created = try values.decodeIfPresent(Int.self, forKey: .created) ?? 0
        size = try values.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sharedSize = try values.decodeIfPresent(Int64.self, forKey: .sharedSize) ?? -1
        containers = try values.decodeIfPresent(Int.self, forKey: .containers) ?? -1
        labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}

/// A volume as `GET /volumes` describes it.
///
/// Note what is **not** here: a size. `/volumes` never reports one — sizes
/// live in `/system/df`'s `UsageData`, which is why the storage area needs
/// both calls and cannot be built from this endpoint alone.
public struct ThrallVolumeDTO: Decodable, Equatable, Sendable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    public let scope: String
    public let createdAt: Date?
    public let labels: [String: String]
    public let usage: Usage?

    public struct Usage: Decodable, Equatable, Sendable {
        /// `0` is the reclaim signal: 93 of the 135 volumes here, 7.3 GB.
        public let refCount: Int
        public let size: Int64

        enum CodingKeys: String, CodingKey { case refCount = "RefCount", size = "Size" }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            refCount = try values.decodeIfPresent(Int.self, forKey: .refCount) ?? -1
            size = try values.decodeIfPresent(Int64.self, forKey: .size) ?? -1
        }
    }

    /// Compose stamps this on every volume it creates without a name.
    public var isAnonymous: Bool { labels["com.docker.volume.anonymous"] != nil }
    /// The compose project that owns it, when one does.
    public var composeProject: String? { labels["com.docker.compose.project"] }

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", mountpoint = "Mountpoint"
        case scope = "Scope", createdAt = "CreatedAt", labels = "Labels", usage = "UsageData"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        driver = try values.decodeIfPresent(String.self, forKey: .driver) ?? ""
        mountpoint = try values.decodeIfPresent(String.self, forKey: .mountpoint) ?? ""
        scope = try values.decodeIfPresent(String.self, forKey: .scope) ?? "local"
        createdAt = ThrallEngineTimestamp.parse(
            try values.decodeIfPresent(String.self, forKey: .createdAt))
        labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        usage = try values.decodeIfPresent(Usage.self, forKey: .usage)
    }
}

/// `GET /volumes` wraps its list, unlike every other list endpoint.
public struct ThrallVolumeListDTO: Decodable, Equatable, Sendable {
    public let volumes: [ThrallVolumeDTO]
    public let warnings: [String]

    enum CodingKeys: String, CodingKey { case volumes = "Volumes", warnings = "Warnings" }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        volumes = try values.decodeIfPresent([ThrallVolumeDTO].self, forKey: .volumes) ?? []
        warnings = try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

/// A network as `GET /networks` describes it.
public struct ThrallNetworkDTO: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let scope: String
    public let created: Date?
    public let internalOnly: Bool
    public let labels: [String: String]

    public var composeProject: String? { labels["com.docker.compose.project"] }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", driver = "Driver", scope = "Scope"
        case created = "Created", internalOnly = "Internal", labels = "Labels"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try values.decodeIfPresent(String.self, forKey: .driver) ?? ""
        scope = try values.decodeIfPresent(String.self, forKey: .scope) ?? "local"
        created = ThrallEngineTimestamp.parse(
            try values.decodeIfPresent(String.self, forKey: .created))
        internalOnly = try values.decodeIfPresent(Bool.self, forKey: .internalOnly) ?? false
        labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}

/// `GET /system/df` — the whole reclaim story in one call.
///
/// Measured here: 24.4 GB of layers, 13 of 30 images unused, 93 of 135 volumes
/// unused, and **289 build-cache entries with zero in use** totalling 17.3 GB.
public struct ThrallDiskUsageDTO: Decodable, Equatable, Sendable {
    public let layersSize: Int64
    public let images: [ThrallImageDTO]
    public let volumes: [ThrallVolumeDTO]
    public let buildCache: [BuildCacheRecord]

    public struct BuildCacheRecord: Decodable, Equatable, Sendable {
        public let id: String
        public let type: String
        public let description: String
        public let inUse: Bool
        public let shared: Bool
        public let size: Int64
        public let createdAt: Date?
        public let lastUsedAt: Date?
        public let usageCount: Int
        public let parents: [String]

        /// **`" Parents"` has a leading space on the wire.** Not a typo here —
        /// verified against this daemon's `/system/df`, where every one of the
        /// 289 records spells it that way. The obvious `"Parents"` decodes to
        /// nil silently, which is the worst possible failure for a field that
        /// exists to build a graph.
        enum CodingKeys: String, CodingKey {
            case id = "ID", type = "Type", description = "Description"
            case inUse = "InUse", shared = "Shared", size = "Size"
            case createdAt = "CreatedAt", lastUsedAt = "LastUsedAt"
            case usageCount = "UsageCount"
            case parents = " Parents"
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
            type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
            description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
            inUse = try values.decodeIfPresent(Bool.self, forKey: .inUse) ?? false
            shared = try values.decodeIfPresent(Bool.self, forKey: .shared) ?? false
            size = try values.decodeIfPresent(Int64.self, forKey: .size) ?? 0
            createdAt = ThrallEngineTimestamp.parse(
                try values.decodeIfPresent(String.self, forKey: .createdAt))
            lastUsedAt = ThrallEngineTimestamp.parse(
                try values.decodeIfPresent(String.self, forKey: .lastUsedAt))
            usageCount = try values.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
            parents = try values.decodeIfPresent([String].self, forKey: .parents) ?? []
        }
    }

    /// Build-cache bytes that nothing is using. The single largest reclaimable
    /// figure on this machine.
    public var reclaimableBuildCache: Int64 {
        buildCache.filter { !$0.inUse }.reduce(0) { $0 + $1.size }
    }

    /// Volume bytes with no container referencing them.
    public var reclaimableVolumes: Int64 {
        volumes.filter { ($0.usage?.refCount ?? -1) == 0 }
            .reduce(0) { $0 + max(0, $1.usage?.size ?? 0) }
    }

    enum CodingKeys: String, CodingKey {
        case layersSize = "LayersSize", images = "Images"
        case volumes = "Volumes", buildCache = "BuildCache"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layersSize = try values.decodeIfPresent(Int64.self, forKey: .layersSize) ?? 0
        images = try values.decodeIfPresent([ThrallImageDTO].self, forKey: .images) ?? []
        volumes = try values.decodeIfPresent([ThrallVolumeDTO].self, forKey: .volumes) ?? []
        buildCache = try values.decodeIfPresent([BuildCacheRecord].self, forKey: .buildCache) ?? []
    }
}

/// The engine's error body: `{"message": "No such container: abc"}`.
struct ThrallEngineMessageDTO: Decodable {
    let message: String
}
