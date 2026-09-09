import Foundation
import Testing
@testable import ThrallFeature

@Suite("ThrallLogFingerprint")
struct ThrallLogFingerprintTests {
    /// Every substitution exists because it is what *differs* between two
    /// containers with one shared cause. Leave any of them in and 12 workers
    /// dying on `connection refused` fingerprint as 12 incidents.
    @Test("two containers failing the same way normalise identically")
    func sameCauseSameFingerprint() {
        let first = "2026-09-09T11:02:54.532431428Z [pid 4127] SQLSTATE[HY000] [2002] "
            + "Connection refused for pgsql:5432 (container f4b70cccfc26)"
        let second = "2026-09-09T11:03:11.118920004Z [pid 5810] SQLSTATE[HY000] [2002] "
            + "Connection refused for pgsql:5433 (container aec9af6e5312)"
        #expect(ThrallLogFingerprint.normalise(first)
            == ThrallLogFingerprint.normalise(second))
    }

    @Test("a genuinely different error does not collapse")
    func differentCauseDifferentFingerprint() {
        #expect(ThrallLogFingerprint.normalise("Connection refused for pgsql:5432")
            != ThrallLogFingerprint.normalise("No such host: pgsql"))
    }

    /// A container that colours its errors must not fingerprint differently
    /// from one that does not.
    @Test("ANSI colour is stripped before fingerprinting")
    func ansiStripped() {
        #expect(ThrallLogFingerprint.normalise("\u{1B}[31mConnection refused\u{1B}[0m")
            == ThrallLogFingerprint.normalise("Connection refused"))
    }

    @Test("timestamps, hex, pids, ports and UUIDs are all replaced", arguments: [
        "2026-09-09T11:02:54Z", "11:02:54.532", "f4b70cccfc268f07294f4d750df50f09",
        "pid 4127", "PID=4127", ":5432",
        "0ab18311-2c30-4dcd-a4da-4d1f9b3535e7",
    ])
    func volatileTokensReplaced(token: String) {
        let normalised = ThrallLogFingerprint.normalise("failure at \(token) end")
        #expect(!normalised.contains(token.lowercased()),
                Comment(rawValue: "\(token) survived as \(normalised)"))
    }

    /// A dying process puts its reason on the last line with anything on it.
    @Test("the last meaningful line is found past trailing blanks")
    func lastMeaningfulLine() {
        let log = "starting\nconnecting\nSQLSTATE[HY000] Connection refused\n\n   \n"
        #expect(ThrallLogFingerprint.lastMeaningfulLine(of: log)
            == "SQLSTATE[HY000] Connection refused")
        #expect(ThrallLogFingerprint.lastMeaningfulLine(of: "\n \n") == nil)
    }

    /// A stack trace on one line would otherwise make the fingerprint the size
    /// of the trace.
    @Test("the fingerprint is bounded")
    func bounded() {
        #expect(ThrallLogFingerprint.normalise(String(repeating: "error ", count: 500)).count <= 200)
    }

    @Test("whitespace padding does not change the fingerprint")
    func whitespaceCollapsed() {
        #expect(ThrallLogFingerprint.normalise("a     b\tc")
            == ThrallLogFingerprint.normalise("a b c"))
    }
}

@Suite("ThrallIncidentGrouper")
struct ThrallIncidentGrouperTests {
    private static let engineKey = "unix:/tmp/docker.sock"
    private static let now = Date(timeIntervalSince1970: 1_789_050_000)

    /// Rebuilds the situation the plan was written against: **15 crash-looping
    /// containers where 12 are one problem.** The live 15 had all given up
    /// before the fixture was captured (`{running 19, exited 28, created 1}`),
    /// so the shape is reconstructed from the real `aai1058` stack — 12 queue
    /// workers on one image all failing to reach `pgsql`, plus three unrelated
    /// failures.
    private func fifteenLoops() -> (world: ThrallWorld, inputs: [ThrallIncidentGrouper.Input]) {
        let stackID = ThrallStackID(engineKey: Self.engineKey, projectName: "aai1058",
                                    workingDirectory: ThrallPathKey("/tmp/wt-1058"))
        let workers = (1...12).map { "queue-\($0)" }

        func service(_ name: String, dependsOn: [String],
                     state: ThrallContainerState) -> ThrallService {
            ThrallService(
                name: name,
                containers: [ThrallContainer(id: "c-\(name)", name: "aai1058-\(name)-1",
                                             image: "aai1058/app:local", state: state,
                                             statusText: "Exited (1) 2 seconds ago",
                                             created: Self.now, replicaNumber: 1,
                                             isOneOff: false)],
                dependsOn: dependsOn.map {
                    ThrallDependency(service: $0, condition: "service_healthy",
                                     restartsDependents: false)
                },
                isDeclaredButAbsent: false)
        }

        var services = workers.map { service($0, dependsOn: ["pgsql"], state: .restarting) }
        // The actual cause, and it is exited — which is the verdict.
        services.append(service("pgsql", dependsOn: [], state: .exited))
        services.append(service("gateway", dependsOn: [], state: .restarting))
        services.append(service("mailpit", dependsOn: [], state: .restarting))
        services.append(service("laravel.test", dependsOn: ["pgsql"], state: .restarting))

        var breakdown = ThrallStateBreakdown()
        for _ in 0..<15 { breakdown.add(.restarting) }
        breakdown.add(.exited)

        let stack = ThrallStack(id: stackID, displayName: "aai1058",
                                workingDirectoryDisplay: "/tmp/wt-1058",
                                configFiles: ["/tmp/wt-1058/docker-compose.yml"],
                                absentConfigFiles: ["/tmp/wt-1058/docker-compose.yml"],
                                services: services.sorted { $0.name < $1.name },
                                breakdown: breakdown, health: .unhealthy,
                                isStaleRelativeToConfig: false)
        let world = ThrallWorld(engineKey: Self.engineKey, stacks: [stack], generatedAt: Self.now)

        func input(_ service: String, exitCode: Int, log: String,
                   digest: String) -> ThrallIncidentGrouper.Input {
            ThrallIncidentGrouper.Input(
                loop: ThrallCrashLoop(
                    stack: stackID, service: service,
                    evidence: .observedDeaths(count: 7, exitCode: exitCode, window: 120),
                    exitCode: exitCode, containerIDs: ["c-\(service)"]),
                logTail: log, imageDigest: digest,
                firstSeen: Self.now.addingTimeInterval(-300), lastSeen: Self.now)
        }

        // The 12 workers: same image, same exit code, same error with volatile
        // details differing — the collapse case.
        var inputs = workers.enumerated().map { index, name in
            input(name, exitCode: 1,
                  log: "2026-09-09T11:0\(index % 10):54.5324Z [pid \(4000 + index)] "
                      + "SQLSTATE[HY000] [2002] Connection refused for pgsql:5432",
                  digest: "sha256:aec9af6e5312")
        }
        // Three unrelated failures, which must stay separate.
        inputs.append(input("gateway", exitCode: 137,
                            log: "2026-09-09T11:02:00Z killed: out of memory",
                            digest: "sha256:1111111111aa"))
        inputs.append(input("mailpit", exitCode: 2,
                            log: "2026-09-09T11:02:00Z bind: address already in use :1025",
                            digest: "sha256:2222222222bb"))
        inputs.append(input("laravel.test", exitCode: 1,
                            log: "2026-09-09T11:02:00Z [pid 9] SQLSTATE[HY000] [2002] "
                                + "Connection refused for pgsql:5432",
                            digest: "sha256:3333333333cc"))
        return (world, inputs)
    }

    /// **The acceptance criterion, and the product thesis.** 15 crash loops
    /// are not 15 problems. Docker Desktop shows 15 red dots and no thesis.
    @Test("fifteen crash loops collapse to four incidents")
    func fifteenCollapseToFour() {
        let (world, inputs) = fifteenLoops()
        #expect(inputs.count == 15)
        let incidents = ThrallIncidentGrouper.group(inputs, world: world)
        #expect(incidents.count <= 4, "the AC")
        #expect(incidents.count == 4)

        let biggest = incidents.max { $0.memberCount < $1.memberCount }!
        #expect(biggest.memberCount == 12)
        #expect(biggest.services.count == 12)
        #expect(biggest.exitCode == 1)
        #expect(biggest.restartTotal == 12 * 7)
    }

    /// The headline is the whole difference: "pgsql is exited — 12 services
    /// blocked", not "12 things are red".
    @Test("the dependency verdict comes free from the labels")
    func dependencyVerdict() throws {
        let (world, inputs) = fifteenLoops()
        let incidents = ThrallIncidentGrouper.group(inputs, world: world)
        let biggest = try #require(incidents.max { $0.memberCount < $1.memberCount })
        let verdict = try #require(biggest.brokenDependencies.first)
        #expect(verdict.dependency == "pgsql")
        #expect(verdict.stateLabel == "exited")
        #expect(biggest.headline == "pgsql is exited — 12 services blocked")
        // Deduped: twelve workers blocked on one dependency is one verdict.
        #expect(biggest.brokenDependencies.count == 1)
    }

    /// **Evidence is the actual error text, never a paraphrase.** The
    /// normalised form is a grouping key and unreadable.
    @Test("the incident carries the un-normalised error text")
    func evidenceIsVerbatim() throws {
        let (world, inputs) = fifteenLoops()
        let biggest = try #require(ThrallIncidentGrouper.group(inputs, world: world)
            .max { $0.memberCount < $1.memberCount })
        let evidence = try #require(biggest.evidence)
        #expect(evidence.contains("SQLSTATE[HY000] [2002] Connection refused"))
        #expect(!evidence.contains("<ts>"), "the fingerprint's tokens must not leak into the UI")
    }

    /// Two services printing the same message from **different images** are
    /// not one problem — which is why the digest is in the key. `laravel.test`
    /// prints the identical error as the workers and stays separate.
    @Test("the same error from a different image is a separate incident")
    func imageDigestSeparates() {
        let (world, inputs) = fifteenLoops()
        let incidents = ThrallIncidentGrouper.group(inputs, world: world)
        let laravel = incidents.filter { $0.services == ["laravel.test"] }
        #expect(laravel.count == 1)
        #expect(laravel[0].memberCount == 1)
    }

    /// The same error in two projects is two problems with two different
    /// fixes, so the stack is part of the key.
    @Test("the same fingerprint in two stacks stays two incidents")
    func stackIsPartOfTheKey() {
        let (world, inputs) = fifteenLoops()
        let other = ThrallStackID(engineKey: Self.engineKey, projectName: "optimus",
                                  workingDirectory: ThrallPathKey("/tmp/optimus"))
        let mirrored = inputs.prefix(3).map { input in
            ThrallIncidentGrouper.Input(
                loop: ThrallCrashLoop(stack: other, service: input.loop.service,
                                      evidence: input.loop.evidence,
                                      exitCode: input.loop.exitCode,
                                      containerIDs: input.loop.containerIDs),
                logTail: input.logTail, imageDigest: input.imageDigest,
                firstSeen: input.firstSeen, lastSeen: input.lastSeen)
        }
        let incidents = ThrallIncidentGrouper.group(inputs + mirrored, world: world)
        #expect(Set(incidents.map(\.stackName)) == ["aai1058", "optimus"])
    }

    /// With no logs read yet, the fingerprint rests on exit code and image —
    /// which still collapses a fleet of identical workers.
    @Test("grouping works before any log has been read")
    func groupsWithoutLogs() {
        let (world, inputs) = fifteenLoops()
        let logless = inputs.map {
            ThrallIncidentGrouper.Input(loop: $0.loop, logTail: nil,
                                        imageDigest: $0.imageDigest,
                                        firstSeen: $0.firstSeen, lastSeen: $0.lastSeen)
        }
        let incidents = ThrallIncidentGrouper.group(logless, world: world)
        #expect(incidents.count == 4)
        #expect(incidents.contains { $0.memberCount == 12 })
    }

    /// The triage list must not reshuffle while the user is reading it, so
    /// ordering is by identity and never by recency or size.
    @Test("incident order is stable and independent of input order")
    func orderingIsStable() {
        let (world, inputs) = fifteenLoops()
        let forward = ThrallIncidentGrouper.group(inputs, world: world).map(\.id)
        let reversed = ThrallIncidentGrouper.group(inputs.reversed(), world: world).map(\.id)
        #expect(forward == reversed)
    }

    @Test("no crash loops means no incidents")
    func empty() {
        let (world, _) = fifteenLoops()
        #expect(ThrallIncidentGrouper.group([], world: world).isEmpty)
    }
}
