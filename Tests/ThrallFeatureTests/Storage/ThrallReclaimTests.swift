import Foundation
import Testing
@testable import ThrallFeature

/// The reclaim rules. **Thrall never calls a bare `prune`** — `docker volume
/// prune` silently eating a database volume is the one unrecoverable mistake
/// this app can make, and 93 of the 135 volumes on the reference machine were
/// unreferenced: precisely the population where it happens.
@Suite("ThrallReclaimPlan")
struct ThrallReclaimPlanTests {
    private func usage(images: [(id: String, tags: [String], size: Int64, containers: Int)] = [],
                       volumes: [(name: String, refCount: Int, size: Int64, project: String?)] = [],
                       cache: [(id: String, inUse: Bool, size: Int64)] = []) throws
        -> ThrallDiskUsageDTO {
        let imageJSON = images.map {
            """
            {"Id":"\($0.id)","RepoTags":\(tagJSON($0.tags)),"Size":\($0.size),\
            "Containers":\($0.containers),"SharedSize":-1}
            """
        }
        let volumeJSON = volumes.map { volume in
            let labels = volume.project.map { #"{"com.docker.compose.project":"\#($0)"}"# } ?? "{}"
            return """
                {"Name":"\(volume.name)","Labels":\(labels),\
                "UsageData":{"RefCount":\(volume.refCount),"Size":\(volume.size)}}
                """
        }
        let cacheJSON = cache.map {
            #"{"ID":"\#($0.id)","InUse":\#($0.inUse),"Size":\#($0.size)}"#
        }
        let json = """
            {"LayersSize":1000,"Images":[\(imageJSON.joined(separator: ","))],\
            "Volumes":[\(volumeJSON.joined(separator: ","))],\
            "BuildCache":[\(cacheJSON.joined(separator: ","))]}
            """
        return try JSONDecoder().decode(ThrallDiskUsageDTO.self, from: Data(json.utf8))
    }

    private func tagJSON(_ tags: [String]) -> String {
        "[" + tags.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// **Volumes are opt-in, never included by default.** They are the only
    /// irreversible part of a reclaim.
    @Test("volumes are excluded unless explicitly asked for")
    func volumesAreOptIn() throws {
        let snapshot = try usage(volumes: [("db_data", 0, 70_000_000, "optimus")])
        let without = ThrallReclaimPlan.make(from: snapshot, includeVolumes: false,
                                             includeImages: true, includeBuildCache: true)
        #expect(without.targets(of: .volume).isEmpty)
        let with = ThrallReclaimPlan.make(from: snapshot, includeVolumes: true,
                                          includeImages: true, includeBuildCache: true)
        #expect(with.targets(of: .volume).count == 1)
    }

    /// A volume something references must never be a target, whatever the
    /// user opted into.
    @Test("a referenced volume is never a target")
    func referencedVolumeIsSafe() throws {
        let snapshot = try usage(volumes: [("live_db", 2, 900_000_000, "optimus"),
                                            ("stale", 0, 70_000_000, nil)])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: true,
                                          includeImages: false, includeBuildCache: false)
        #expect(plan.targets.map(\.identifier) == ["stale"])
    }

    /// An image a container uses must never be a target — removing it breaks a
    /// running stack.
    @Test("an image in use is never a target")
    func usedImageIsSafe() throws {
        let snapshot = try usage(images: [("sha256:used", ["app:latest"], 400, 3),
                                           ("sha256:free", [], 500, 0)])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: false,
                                          includeImages: true, includeBuildCache: false)
        #expect(plan.targets.map(\.identifier) == ["sha256:free"])
        #expect(plan.targets[0].reason.contains("untagged"))
    }

    @Test("build cache in use is never a target")
    func usedCacheIsSafe() throws {
        let snapshot = try usage(cache: [("a", true, 1_000), ("b", false, 17)])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: false,
                                          includeImages: false, includeBuildCache: true)
        #expect(plan.targets.map(\.identifier) == ["b"])
    }

    /// The user is deciding what to delete, and size is the only reason to
    /// delete anything here.
    @Test("targets are ordered largest first")
    func largestFirst() throws {
        let snapshot = try usage(
            images: [("sha256:small", [], 10, 0), ("sha256:big", [], 10_000, 0)],
            volumes: [("mid", 0, 500, nil)],
            cache: [("c", false, 5_000)])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: true,
                                          includeImages: true, includeBuildCache: true)
        #expect(plan.targets.map(\.bytes) == plan.targets.map(\.bytes).sorted(by: >))
    }

    /// **The confirmation must name volumes separately and say the word.**
    /// A generic "remove 40 items?" is how someone loses a database.
    @Test("the confirmation names volumes and says data cannot be recovered")
    func confirmationIsExplicitAboutVolumes() throws {
        let snapshot = try usage(volumes: [("optimus_db", 0, 70_000_000, "optimus"),
                                            ("althaqeel_pg", 0, 30_000_000, "althaqeel")])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: true,
                                          includeImages: false, includeBuildCache: false)
        let text = plan.confirmation()
        #expect(text.contains("VOLUMES"))
        #expect(text.contains("cannot be recovered"))
        #expect(text.contains("optimus_db"))
        #expect(text.contains("althaqeel_pg"))
        // And it states the contract.
        #expect(text.contains("does not run `prune`"))
    }

    @Test("a volume-free plan does not mention volumes at all")
    func confirmationWithoutVolumes() throws {
        let snapshot = try usage(images: [("sha256:free", [], 500, 0)])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: false,
                                          includeImages: true, includeBuildCache: false)
        #expect(!plan.confirmation().contains("VOLUMES"))
    }

    /// Every target carries the **exact** identifier removal will use — never
    /// a display string, and never something re-derived later.
    @Test("every target carries a non-empty exact identifier")
    func identifiersAreExact() throws {
        let snapshot = try usage(
            images: [("sha256:abc", ["a:1"], 1, 0)],
            volumes: [("vol", 0, 1, nil)],
            cache: [("cache-id", false, 1)])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: true,
                                          includeImages: true, includeBuildCache: true)
        #expect(plan.targets.allSatisfy { !$0.identifier.isEmpty })
        #expect(plan.targets.contains { $0.identifier == "sha256:abc" })
        #expect(plan.targets.contains { $0.identifier == "vol" })
        #expect(plan.targets.contains { $0.identifier == "cache-id" })
    }

    /// An image id and a volume name can collide, and a list that silently
    /// drops a row is how the wrong thing gets deleted.
    @Test("target ids are unique even when an image and a volume share a name")
    func idsAreKindPrefixed() throws {
        let snapshot = try usage(images: [("same", [], 1, 0)],
                                  volumes: [("same", 0, 1, nil)])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: true,
                                          includeImages: true, includeBuildCache: false)
        #expect(plan.targets.count == 2)
        #expect(Set(plan.targets.map(\.id)).count == 2)
    }

    @Test("an unused volume's reason warns rather than reassures")
    func volumeReasonWarns() throws {
        let snapshot = try usage(volumes: [("named_db", 0, 1, "optimus")])
        let plan = ThrallReclaimPlan.make(from: snapshot, includeVolumes: true,
                                          includeImages: false, includeBuildCache: false)
        #expect(plan.targets[0].reason.contains("check this is not data you want"))
    }

    @Test("byte formatting is human and stable", arguments: [
        (Int64(0), "0 B"), (Int64(1023), "1023 B"), (Int64(1024), "1.0 KB"),
        (Int64(1_048_576), "1.0 MB"), (Int64(24_503_210_805), "22.8 GB"),
    ])
    func humanBytes(value: Int64, expected: String) {
        #expect(ThrallReclaimPlan.humanBytes(value) == expected)
    }

    @Test("an empty snapshot yields an empty plan")
    func emptySnapshot() throws {
        let plan = ThrallReclaimPlan.make(from: try usage(), includeVolumes: true,
                                          includeImages: true, includeBuildCache: true)
        #expect(plan.isEmpty)
        #expect(plan.totalBytes == 0)
    }
}

@MainActor
@Suite("ThrallStorageModel")
struct ThrallStorageModelTests {
    /// **135 rows must never hit an eager table.** `AinkradDataTable` is a
    /// `VStack` + `ForEach`, so grouping into collapsed disclosures is what
    /// keeps the area openable.
    @Test("volumes group by owner with unowned last")
    func groupingPutsUnownedLast() throws {
        let model = ThrallStorageModel()
        let json = """
            {"LayersSize":0,"Images":[],"BuildCache":[],"Volumes":[
              {"Name":"a1","Labels":{"com.docker.compose.project":"optimus"},
               "UsageData":{"RefCount":1,"Size":10}},
              {"Name":"z9","Labels":{},"UsageData":{"RefCount":0,"Size":900}},
              {"Name":"b2","Labels":{"com.docker.compose.project":"althaqeel"},
               "UsageData":{"RefCount":0,"Size":20}}]}
            """
        let usage = try JSONDecoder().decode(ThrallDiskUsageDTO.self, from: Data(json.utf8))
        model.applyForTesting(usage: usage)
        let groups = model.volumeGroups
        #expect(groups.map(\.owner) == ["althaqeel", "optimus", ThrallStorageModel.unownedGroup])
        #expect(groups.last?.bytes == 900)
    }

    /// Absence means selected, so a target that appears after the user last
    /// looked is included rather than silently skipped — and excluding is an
    /// explicit act that survives a reload.
    @Test("excluding a target removes it from the plan")
    func exclusionApplies() throws {
        let model = ThrallStorageModel()
        let json = """
            {"LayersSize":0,"Volumes":[],"BuildCache":[],
             "Images":[{"Id":"sha256:a","RepoTags":[],"Size":100,"Containers":0,"SharedSize":-1},
                       {"Id":"sha256:b","RepoTags":[],"Size":50,"Containers":0,"SharedSize":-1}]}
            """
        model.applyForTesting(
            usage: try JSONDecoder().decode(ThrallDiskUsageDTO.self, from: Data(json.utf8)))
        #expect(model.plan.targets.count == 2)
        model.excluded.insert("image:sha256:a")
        #expect(model.plan.targets.map(\.identifier) == ["sha256:b"])
    }

    @Test("volumes stay out of the plan until opted in")
    func volumesOptIn() throws {
        let model = ThrallStorageModel()
        let json = """
            {"LayersSize":0,"Images":[],"BuildCache":[],
             "Volumes":[{"Name":"v","Labels":{},"UsageData":{"RefCount":0,"Size":1}}]}
            """
        model.applyForTesting(
            usage: try JSONDecoder().decode(ThrallDiskUsageDTO.self, from: Data(json.utf8)))
        #expect(model.plan.isEmpty)
        model.includeVolumes = true
        #expect(model.plan.targets.count == 1)
    }
}
