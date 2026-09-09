import Foundation
import Testing
@testable import ThrallFeature

@Suite("ThrallEvent")
struct ThrallEventTests {
    /// **The measured hazard.** 256 events in an hour on this machine, all of
    /// them healthcheck execs, and every action arrives prefixed with its
    /// argument — so `action == "die"` never matches what you expect and
    /// `exec_die` is one string away from `die`.
    @Test("the action is split off its argument", arguments: [
        ("die", ThrallEvent.Action.die),
        ("start", .start),
        ("exec_die: /bin/sh -c mysqladmin ping", .exec("exec_die")),
        ("exec_create: /bin/sh -c mysqladmin ping", .exec("exec_create")),
        ("exec_start: /bin/sh -c mysqladmin ping", .exec("exec_start")),
        ("health_status: healthy", .healthStatus("healthy")),
        ("health_status: unhealthy", .healthStatus("unhealthy")),
        ("rename", .other("rename")),
    ])
    func actionParsing(raw: String, expected: ThrallEvent.Action) {
        #expect(ThrallEvent.parseAction(raw) == expected)
    }

    /// The one that would actually cause a bug: `exec_die` must never be
    /// mistaken for a container dying, or every healthcheck probe becomes a
    /// crash-loop data point and 100% of this machine's traffic is noise.
    @Test("exec_die is not die")
    func execDieIsNotDie() {
        #expect(ThrallEvent.parseAction("exec_die: /bin/sh -c pg_isready") != .die)
    }

    @Test("a real die event decodes with its exit code and compose labels")
    func decodesDie() throws {
        let line = Data("""
            {"status":"die","id":"f4b70cccfc26","Type":"container","Action":"die",
             "Actor":{"ID":"f4b70cccfc26","Attributes":{
               "com.docker.compose.project":"aai1058",
               "com.docker.compose.project.working_dir":"/tmp/wt-1058",
               "com.docker.compose.service":"worker","exitCode":"1",
               "name":"aai1058-worker-1","image":"aai1058/worker:local"}},
             "scope":"local","time":1789041600}
            """.utf8)
        let event = try #require(ThrallEventDTO.parse(line: line))
        #expect(event.action == .die)
        #expect(event.isContainer)
        #expect(event.exitCode == 1)
        #expect(event.composeProject == "aai1058")
        #expect(event.composeService == "worker")
        #expect(event.containerName == "aai1058-worker-1")
    }

    /// A malformed event costs one history entry. A throw would kill the
    /// stream the whole triage feed depends on.
    @Test("a malformed line is dropped, not thrown", arguments: [
        "", "{", "null", "[]", #"{"Type":"container"}"#, #"{"Action":""}"#,
    ])
    func malformedLinesDropped(text: String) {
        #expect(ThrallEventDTO.parse(line: Data(text.utf8)) == nil)
    }

    /// Verbatim from this machine's `/events`: an hour of pure healthcheck
    /// noise. Not one of them may reach the history.
    @Test("an hour of real healthcheck traffic contributes nothing to history")
    func healthcheckNoiseIsIgnored() {
        var history = ThrallEventHistory()
        let actions = ["exec_create: /bin/sh -c mysqladmin ping -h 127.0.0.1",
                       "exec_start: /bin/sh -c mysqladmin ping -h 127.0.0.1",
                       "exec_die: /bin/sh -c mysqladmin ping -h 127.0.0.1",
                       "health_status: healthy"]
        for index in 0..<256 {
            let event = ThrallEvent(
                type: "container",
                action: ThrallEvent.parseAction(actions[index % actions.count]),
                containerID: "c\(index % 12)",
                time: Date(timeIntervalSince1970: 1_789_041_600 + Double(index)),
                attributes: ["com.docker.compose.project": "aai1058",
                             "com.docker.compose.service": "worker",
                             "exitCode": "0"])
            history.record(event, engineKey: "e")
        }
        #expect(history.trackedServices.isEmpty)
    }
}

@Suite("ThrallEventHistory")
struct ThrallEventHistoryTests {
    private func die(container: String, exitCode: Int, at seconds: Double,
                     service: String = "worker") -> ThrallEvent {
        ThrallEvent(type: "container", action: .die, containerID: container,
                    time: Date(timeIntervalSince1970: seconds),
                    attributes: ["com.docker.compose.project": "aai1058",
                                 "com.docker.compose.project.working_dir": "/tmp/wt",
                                 "com.docker.compose.service": service,
                                 "exitCode": String(exitCode)])
    }

    /// **Keyed per service, not per container.** Compose assigns a new
    /// container id on every recreate, so a container-keyed history shows six
    /// containers that each died once instead of one service that died six
    /// times — the wrong answer, and the reason signals dedupe per service.
    @Test("deaths across recreates accumulate on one service key")
    func survivesRecreates() {
        var history = ThrallEventHistory()
        for index in 0..<6 {
            history.record(die(container: "recreated-\(index)", exitCode: 1,
                               at: 1_000 + Double(index)), engineKey: "e")
        }
        #expect(history.trackedServices.count == 1)
        let key = history.trackedServices[0]
        #expect(history.deaths(for: key).count == 6)
        #expect(Set(history.deaths(for: key).map(\.containerID)).count == 6)
    }

    @Test("history is bounded — /events stays open for the whole session")
    func bounded() {
        var history = ThrallEventHistory(limitPerService: 5)
        for index in 0..<50 {
            history.record(die(container: "c", exitCode: 1, at: Double(index)), engineKey: "e")
        }
        let key = history.trackedServices[0]
        #expect(history.deaths(for: key).count == 5)
        // The newest are kept.
        #expect(history.deaths(for: key).last?.at == Date(timeIntervalSince1970: 49))
    }

    @Test("the recency window filters older deaths")
    func recencyWindow() {
        var history = ThrallEventHistory()
        history.record(die(container: "a", exitCode: 1, at: 1_000), engineKey: "e")
        history.record(die(container: "b", exitCode: 1, at: 2_000), engineKey: "e")
        let key = history.trackedServices[0]
        #expect(history.recentDeaths(for: key,
                                     since: Date(timeIntervalSince1970: 1_500)).count == 1)
    }

    @Test("pruning drops services that no longer exist")
    func pruning() {
        var history = ThrallEventHistory()
        history.record(die(container: "a", exitCode: 1, at: 1, service: "gone"), engineKey: "e")
        history.record(die(container: "b", exitCode: 1, at: 2, service: "kept"), engineKey: "e")
        let kept = history.trackedServices.first { $0.service == "kept" }
        history.prune(keeping: Set([kept!]))
        #expect(history.trackedServices.map(\.service) == ["kept"])
    }
}

@Suite("ThrallCrashLoopDetector")
struct ThrallCrashLoopDetectorTests {
    private static let stack = ThrallStackID(engineKey: "e", projectName: "aai1058",
                                             workingDirectory: ThrallPathKey("/tmp/wt"))
    private static let now = Date(timeIntervalSince1970: 1_789_050_000)

    private func container(_ id: String) -> ThrallContainer {
        ThrallContainer(id: id, name: "aai1058-worker-1", image: "aai1058/worker:local",
                        state: .exited, statusText: "Exited (1) 2 seconds ago",
                        created: Self.now, replicaNumber: 1, isOneOff: false)
    }

    private func history(deaths: Int, exitCode: Int = 1, spacing: Double = 5,
                         service: String = "worker") -> ThrallEventHistory {
        var history = ThrallEventHistory()
        for index in 0..<deaths {
            history.record(ThrallEvent(
                type: "container", action: .die, containerID: "c\(index)",
                time: Self.now.addingTimeInterval(-spacing * Double(index)),
                attributes: ["com.docker.compose.project": "aai1058",
                             "com.docker.compose.project.working_dir": "/tmp/wt",
                             "com.docker.compose.service": service,
                             "exitCode": String(exitCode)]), engineKey: "e")
        }
        return history
    }

    private func candidate(restartCount: Int = 0, canRestart: Bool = true,
                           finishedAt: Date? = nil) -> ThrallCrashLoopDetector.Candidate {
        ThrallCrashLoopDetector.Candidate(
            stack: Self.stack, service: "worker", containers: [container("c0")],
            restartCounts: ["c0": restartCount],
            restartPolicies: ["c0": canRestart],
            finishedAt: finishedAt.map { ["c0": $0] } ?? [:])
    }

    @Test("three deaths with the same nonzero exit code inside the window is a loop")
    func warmDetection() throws {
        let loop = try #require(ThrallCrashLoopDetector.detect(
            candidate: candidate(), history: history(deaths: 7), now: Self.now))
        #expect(loop.service == "worker")
        #expect(loop.exitCode == 1)
        // The evidence that lets a row say "restarting x7, exit 1".
        #expect(loop.evidence == .observedDeaths(count: 7, exitCode: 1, window: 120))
        #expect(loop.containerIDs.count == 7)
    }

    /// Below three, an ordinary restart or a `compose up` recreate would
    /// qualify.
    @Test("two deaths is not a loop")
    func belowThreshold() {
        #expect(ThrallCrashLoopDetector.detect(candidate: candidate(),
                                               history: history(deaths: 2),
                                               now: Self.now) == nil)
    }

    /// Written first with 60 s spacing, which **passed the detector** — and it
    /// was the test that was wrong, not the rule: a service dying every minute
    /// is a crash loop by any reading. At 70 s only two deaths land inside the
    /// 120 s window, which is the actual boundary.
    @Test("deaths spread beyond the window do not count")
    func outsideWindow() {
        #expect(ThrallCrashLoopDetector.detect(candidate: candidate(),
                                               history: history(deaths: 5, spacing: 70),
                                               now: Self.now) == nil)
    }

    @Test("a death every minute does qualify — three land inside the window")
    func minuteCadenceIsALoop() {
        #expect(ThrallCrashLoopDetector.detect(candidate: candidate(),
                                               history: history(deaths: 5, spacing: 60),
                                               now: Self.now) != nil)
    }

    /// A clean exit repeated is a job finishing, not a crash.
    @Test("repeated exit code 0 is not a crash loop")
    func zeroExitIsNotACrash() {
        #expect(ThrallCrashLoopDetector.detect(candidate: candidate(),
                                               history: history(deaths: 6, exitCode: 0),
                                               now: Self.now) == nil)
    }

    /// Different exit codes each time means a flapping *cause*, not one loop —
    /// so it does not meet the same-code threshold.
    @Test("deaths with differing exit codes do not group into one loop")
    func mixedExitCodes() {
        var history = ThrallEventHistory()
        for (index, code) in [1, 2, 137, 143, 1].enumerated() {
            history.record(ThrallEvent(
                type: "container", action: .die, containerID: "c\(index)",
                time: Self.now.addingTimeInterval(-Double(index) * 5),
                attributes: ["com.docker.compose.project": "aai1058",
                             "com.docker.compose.project.working_dir": "/tmp/wt",
                             "com.docker.compose.service": "worker",
                             "exitCode": String(code)]), engineKey: "e")
        }
        #expect(ThrallCrashLoopDetector.detect(candidate: candidate(), history: history,
                                               now: Self.now) == nil)
    }

    /// **Checked first, and not an optimisation.** A container the engine will
    /// not restart exited once; it is not in a loop. Without this, every
    /// one-shot migration job that exits nonzero — `laravel-migrate`,
    /// `desking-migrate` on this machine — is reported as a crash loop
    /// forever.
    @Test("a container with RestartPolicy `no` can never be a crash loop")
    func restartPolicyNo() {
        #expect(ThrallCrashLoopDetector.detect(candidate: candidate(canRestart: false),
                                               history: history(deaths: 20),
                                               now: Self.now) == nil)
    }

    /// **The recency clause.** `RestartCount` is lifetime-cumulative, so
    /// without it every long-lived container on a laptop that sleeps looks
    /// like a crash loop and the plugin becomes a spam source on first launch.
    @Test("RestartCount alone is not enough — it needs a recent death")
    func restartCountNeedsRecency() {
        let old = Self.now.addingTimeInterval(-60 * 60 * 24 * 7)
        #expect(ThrallCrashLoopDetector.detect(
            candidate: candidate(restartCount: 41, finishedAt: old),
            history: ThrallEventHistory(), now: Self.now) == nil)

        let recent = Self.now.addingTimeInterval(-30)
        let loop = ThrallCrashLoopDetector.detect(
            candidate: candidate(restartCount: 41, finishedAt: recent),
            history: ThrallEventHistory(), now: Self.now)
        #expect(loop?.evidence == .restartCount(41, since: recent))
    }

    /// **The live-run bug.** Docker's restart backoff is exponential, so a
    /// container at `RestartCount: 13` was dying every ~40 s — only two deaths
    /// inside the 120 s window. Warm detection fails, and the first version
    /// then refused to fall back to `RestartCount` because *some* deaths had
    /// been seen. Thrall went blind on the long-running loops that matter most.
    @Test("a slow loop is caught by RestartCount even though some deaths were observed")
    func partialHistoryStillFallsBackToRestartCount() throws {
        let recentFinish = Self.now.addingTimeInterval(-37)
        let loop = try #require(ThrallCrashLoopDetector.detect(
            candidate: candidate(restartCount: 13, finishedAt: recentFinish),
            // Two deaths only: below the threshold, but not zero.
            history: history(deaths: 2), now: Self.now))
        #expect(loop.evidence == .restartCount(13, since: recentFinish))
    }

    @Test("RestartCount with no finish time at all is not trusted")
    func restartCountWithoutFinishTime() {
        #expect(ThrallCrashLoopDetector.detect(candidate: candidate(restartCount: 41),
                                               history: ThrallEventHistory(),
                                               now: Self.now) == nil)
    }

    /// Once events exist for a service they are authoritative over the
    /// cumulative count — otherwise a service that has settled would keep
    /// being reported from its history.
    @Test("observed deaths take precedence over RestartCount")
    func eventsBeatRestartCount() {
        let loop = ThrallCrashLoopDetector.detect(
            candidate: candidate(restartCount: 99,
                                 finishedAt: Self.now.addingTimeInterval(-10)),
            history: history(deaths: 4), now: Self.now)
        #expect(loop?.evidence == .observedDeaths(count: 4, exitCode: 1, window: 120))
    }

    @Test("detection is ordered by identity, not by restart count")
    func orderingIsStable() {
        let services = ["zebra", "alpha", "middle"]
        let candidates = services.map { name in
            ThrallCrashLoopDetector.Candidate(
                stack: Self.stack, service: name, containers: [container("c-\(name)")],
                restartPolicies: ["c-\(name)": true])
        }
        var combined = ThrallEventHistory()
        for (index, name) in services.enumerated() {
            for death in 0..<(3 + index * 4) {
                combined.record(ThrallEvent(
                    type: "container", action: .die, containerID: "c\(death)",
                    time: Self.now.addingTimeInterval(-Double(death)),
                    attributes: ["com.docker.compose.project": "aai1058",
                                 "com.docker.compose.project.working_dir": "/tmp/wt",
                                 "com.docker.compose.service": name,
                                 "exitCode": "1"]), engineKey: "e")
            }
        }
        let detected = ThrallCrashLoopDetector.detectAll(candidates: candidates,
                                                          history: combined, now: Self.now)
        #expect(detected.map(\.service) == ["alpha", "middle", "zebra"])
    }
}
