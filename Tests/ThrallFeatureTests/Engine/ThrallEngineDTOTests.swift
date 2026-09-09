import Foundation
import Testing
@testable import ThrallFeature

/// Each of these pins one thing the engine's JSON does that a straightforward
/// `Decodable` gets wrong — silently, in every case.
@Suite("Engine DTOs")
struct ThrallEngineDTOTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Timestamps

    /// Neither `ISO8601DateFormatter` configuration parses both shapes, and the
    /// engine sends both **in the same response**: `/system/df` has fractional
    /// build-cache timestamps beside non-fractional volume ones.
    @Test("both timestamp shapes the engine sends parse", arguments: [
        "2026-09-09T11:02:54.532431428Z",
        "2026-08-24T09:31:56+03:00",
        "2026-08-23T16:07:15.478929157+03:00",
        "2026-08-26T07:10:09.225284435Z",
    ])
    func parsesBothTimestampShapes(raw: String) {
        #expect(ThrallEngineTimestamp.parse(raw) != nil, "failed to parse \(raw)")
    }

    /// The Go zero time is a sentinel meaning "this never happened". Parsed as
    /// a date it renders as "exited 2025 years ago".
    @Test("the Go zero time maps to nil, not to the year 1")
    func zeroTimeIsNotADate() {
        #expect(ThrallEngineTimestamp.parse("0001-01-01T00:00:00Z") == nil)
        #expect(ThrallEngineTimestamp.parse("0001-01-01T00:00:00.000000000Z") == nil)
        #expect(ThrallEngineTimestamp.parse(nil) == nil)
        #expect(ThrallEngineTimestamp.parse("") == nil)
    }

    // MARK: - Inspect

    @Test("inspect decodes the fields crash-loop detection needs")
    func inspectDecodes() throws {
        let dto = try decode(ThrallContainerInspectDTO.self, """
            {"Id":"f4b70cccfc26","Name":"/optimus-scheduler-1",
             "Created":"2026-09-09T11:02:43.411262135Z","RestartCount":7,
             "State":{"Status":"running","Running":true,"Paused":false,"Restarting":false,
                      "OOMKilled":false,"Dead":false,"Pid":96737,"ExitCode":0,"Error":"",
                      "StartedAt":"2026-09-09T11:02:54.532431428Z",
                      "FinishedAt":"0001-01-01T00:00:00Z"},
             "HostConfig":{"RestartPolicy":{"Name":"unless-stopped","MaximumRetryCount":0}},
             "Config":{"Tty":false}}
            """)
        #expect(dto.name == "optimus-scheduler-1")
        #expect(dto.restartCount == 7)
        #expect(dto.created != nil)
        #expect(dto.state.startedAt != nil)
        #expect(dto.state.finishedAt == nil)
        #expect(dto.restartPolicy.canRestart)
        #expect(!dto.hasTTY)
    }

    /// A container the engine will not restart cannot be in a crash loop.
    /// Checking this first is what keeps a one-shot job that exited 1 out of
    /// the triage feed.
    @Test("a restart policy of `no` cannot crash-loop", arguments: [
        ("no", false), ("", false), ("always", true), ("unless-stopped", true), ("on-failure", true),
    ])
    func restartPolicy(name: String, canRestart: Bool) throws {
        let dto = try decode(ThrallContainerInspectDTO.self, """
            {"Id":"a","Name":"/a","State":{"Status":"exited"},
             "HostConfig":{"RestartPolicy":{"Name":"\(name)"}}}
            """)
        #expect(dto.restartPolicy.canRestart == canRestart)
    }

    @Test("inspect survives a missing HostConfig or Config")
    func inspectWithMissingSections() throws {
        let dto = try decode(ThrallContainerInspectDTO.self,
                             #"{"Id":"a","Name":"/a","State":{"Status":"exited"}}"#)
        #expect(!dto.restartPolicy.canRestart)
        #expect(!dto.hasTTY)
    }

    // MARK: - Images

    /// **`-1` means "not computed", not "zero".** `/images/json` only computes
    /// shared size when asked, and summing the sentinel produces a negative
    /// total.
    @Test("SharedSize -1 reports as nil rather than as a number")
    func sharedSizeSentinel() throws {
        let dto = try decode(ThrallImageDTO.self, """
            {"Id":"sha256:ea8c","ParentId":"","RepoTags":[],"RepoDigests":[],
             "Created":1788889573,"Size":446636308,"SharedSize":-1,"Containers":0,"Labels":{}}
            """)
        #expect(dto.computedSharedSize == nil)
        #expect(dto.size == 446_636_308)
        #expect(dto.isDangling, "no tags is what `<none>:<none>` means in docker images")
        #expect(dto.containers == 0, "zero containers is the reclaim signal")
    }

    @Test("a computed shared size is reported as itself")
    func sharedSizeComputed() throws {
        let dto = try decode(ThrallImageDTO.self,
                             #"{"Id":"a","RepoTags":["app:latest"],"SharedSize":10285056}"#)
        #expect(dto.computedSharedSize == 10_285_056)
        #expect(!dto.isDangling)
    }

    // MARK: - Volumes

    /// `/volumes` never reports a size — sizes live in `/system/df`'s
    /// `UsageData`. So the storage area needs both calls, and this endpoint's
    /// `usage` really is nil.
    @Test("a volume from /volumes has no usage data at all")
    func volumeWithoutUsage() throws {
        let dto = try decode(ThrallVolumeDTO.self, """
            {"CreatedAt":"2026-08-24T09:31:56+03:00","Driver":"local",
             "Labels":{"com.docker.volume.anonymous":""},
             "Mountpoint":"/var/lib/docker/volumes/426964a5/_data",
             "Name":"426964a5","Options":null,"Scope":"local"}
            """)
        #expect(dto.usage == nil)
        #expect(dto.isAnonymous)
        #expect(dto.composeProject == nil)
        // `Options: null` is real, and would throw against a non-optional.
        #expect(dto.createdAt != nil)
    }

    @Test("a volume from /system/df carries the reclaim signal")
    func volumeWithUsage() throws {
        let dto = try decode(ThrallVolumeDTO.self, """
            {"Name":"optimus_db","Driver":"local","Labels":{"com.docker.compose.project":"optimus"},
             "UsageData":{"RefCount":0,"Size":70001785}}
            """)
        #expect(dto.usage?.refCount == 0)
        #expect(dto.composeProject == "optimus")
    }

    @Test("the volume list is wrapped, unlike every other list endpoint")
    func volumeListIsWrapped() throws {
        let dto = try decode(ThrallVolumeListDTO.self,
                             #"{"Volumes":[{"Name":"a"}],"Warnings":null}"#)
        #expect(dto.volumes.count == 1)
        #expect(dto.warnings.isEmpty)
    }

    // MARK: - Disk usage

    /// **The build-cache key has a leading space on the wire.** Verified
    /// against this daemon, where all 289 records spell it `" Parents"`. The
    /// obvious `"Parents"` decodes to nil silently — the worst failure for a
    /// field whose only purpose is to build a graph.
    @Test("build cache decodes the leading-space Parents key the engine sends")
    func buildCacheLeadingSpaceKey() throws {
        let dto = try decode(ThrallDiskUsageDTO.self, """
            {"LayersSize":24503210805,"Images":[],"Containers":[],"Volumes":[],
             "BuildCache":[{"ID":"norvxdttv6brxaa49mjvwo008"," Parents":["vslb5p0w3ci50vi9f1mcl4llm"],
              "Type":"regular","Description":"pulled from docker.io/library/python:3.12-alpine",
              "InUse":false,"Shared":false,"Size":411757,
              "CreatedAt":"2026-08-26T07:10:09.225284435Z",
              "LastUsedAt":"2026-08-26T07:10:09.275588018Z","UsageCount":1}]}
            """)
        let record = try #require(dto.buildCache.first)
        #expect(record.parents == ["vslb5p0w3ci50vi9f1mcl4llm"])
        #expect(record.createdAt != nil)
        #expect(record.lastUsedAt != nil)
        #expect(dto.layersSize == 24_503_210_805)
    }

    @Test("reclaimable totals count only what nothing is using")
    func reclaimableTotals() throws {
        let dto = try decode(ThrallDiskUsageDTO.self, """
            {"LayersSize":100,
             "Volumes":[{"Name":"used","UsageData":{"RefCount":2,"Size":900}},
                        {"Name":"free","UsageData":{"RefCount":0,"Size":70}},
                        {"Name":"unknown","UsageData":{"RefCount":-1,"Size":5}}],
             "BuildCache":[{"ID":"a","InUse":true,"Size":1000},
                           {"ID":"b","InUse":false,"Size":17},
                           {"ID":"c","InUse":false,"Size":3}]}
            """)
        #expect(dto.reclaimableVolumes == 70)
        #expect(dto.reclaimableBuildCache == 20)
    }

    @Test("a df response missing whole sections decodes to empties")
    func partialDiskUsage() throws {
        let dto = try decode(ThrallDiskUsageDTO.self, #"{"LayersSize":42}"#)
        #expect(dto.images.isEmpty && dto.volumes.isEmpty && dto.buildCache.isEmpty)
        #expect(dto.reclaimableBuildCache == 0)
    }

    // MARK: - Networks

    @Test("a network reports the compose project that owns it")
    func network() throws {
        let dto = try decode(ThrallNetworkDTO.self, """
            {"Name":"compose_default","Id":"91c25cc5","Created":"2026-08-23T16:07:15.478929157+03:00",
             "Scope":"local","Driver":"bridge","Internal":false,
             "Labels":{"com.docker.compose.project":"compose","com.docker.compose.network":"default"}}
            """)
        #expect(dto.composeProject == "compose")
        #expect(dto.created != nil)
        #expect(!dto.internalOnly)
    }
}
