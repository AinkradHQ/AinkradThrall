import Foundation
import Testing
@testable import ThrallFeature

@Suite("ThrallRemedy")
struct ThrallRemedyTests {
    private static let stackID = ThrallStackID(engineKey: "e", projectName: "aai1058",
                                                workingDirectory: ThrallPathKey("/tmp/wt"))

    private func incident(dependency: String? = "pgsql",
                          services: [String] = ["queue-1", "queue-2", "queue-3"]) -> ThrallIncident {
        ThrallIncident(
            key: .init(stack: Self.stackID, fingerprint: "1|connection refused|sha256:aec"),
            stackName: "aai1058",
            services: services,
            containerIDs: services.map { "c-\($0)" },
            exitCode: 1,
            evidence: "SQLSTATE[HY000] [2002] Connection refused",
            imageDigest: "sha256:aec",
            firstSeen: Date(timeIntervalSince1970: 1_000),
            lastSeen: Date(timeIntervalSince1970: 2_000),
            restartTotal: 21,
            brokenDependencies: dependency.map {
                [ThrallDependencyVerdict(dependent: services[0], dependency: $0,
                                         condition: "service_healthy", stateLabel: "exited")]
            } ?? [])
    }

    private func stack(configMissing: Bool) -> ThrallStack {
        ThrallStack(id: Self.stackID, displayName: "aai1058",
                    workingDirectoryDisplay: "/tmp/wt",
                    configFiles: ["/tmp/wt/docker-compose.yml"],
                    absentConfigFiles: configMissing ? ["/tmp/wt/docker-compose.yml"] : [],
                    services: [], breakdown: ThrallStateBreakdown(),
                    health: .unhealthy, isStaleRelativeToConfig: false)
    }

    /// **Ordered by decreasing confidence, and the ordering is the advice.**
    /// The AC's remedy #1 for the aai1058 case is restart the dependency, then
    /// the dependents.
    @Test("remedy #1 restarts the dependency then its dependents")
    func primaryRemedyIsTheDependency() throws {
        let remedies = ThrallRemedy.remedies(for: incident(), stack: stack(configMissing: false))
        let first = try #require(remedies.first)
        guard case .restartDependencyThenDependents(let dependency, let dependents) = first.kind else {
            Issue.record("expected the dependency remedy first, got \(first.kind)")
            return
        }
        #expect(dependency == "pgsql")
        #expect(dependents == ["queue-1", "queue-2", "queue-3"])
        #expect(first.commandPreview.contains("restart -- pgsql"))
        #expect(!first.destroysState)
        // Confidence really is descending.
        #expect(remedies.map(\.confidence) == remedies.map(\.confidence).sorted(by: >))
    }

    /// **Restarting an already-broken service does not confirm.** Gating the
    /// action that fixes the problem is what makes people stop using the tool.
    @Test("no restart remedy claims to destroy state")
    func restartsDoNotDestroyState() {
        for missing in [true, false] {
            let remedies = ThrallRemedy.remedies(for: incident(), stack: stack(configMissing: missing))
            for remedy in remedies {
                switch remedy.kind {
                case .restartServices, .restartDependencyThenDependents, .upStack, .pullStack:
                    #expect(!remedy.destroysState, Comment(rawValue: remedy.title))
                case .teardownByLabel:
                    #expect(remedy.destroysState)
                }
            }
        }
    }

    /// An orphaned stack cannot use compose at all, so it must not be offered
    /// a compose remedy that would simply fail.
    @Test("an orphaned stack is offered engine-level remedies only")
    func orphanedStackRemedies() {
        let remedies = ThrallRemedy.remedies(for: incident(), stack: stack(configMissing: true))
        #expect(!remedies.contains { $0.kind == .upStack || $0.kind == .pullStack })
        #expect(remedies.contains { $0.kind == .teardownByLabel })
        // And the teardown says out loud that it goes by label — which is what
        // makes it work where `docker compose down` cannot.
        let teardown = remedies.first { $0.kind == .teardownByLabel }
        #expect(teardown?.commandPreview.contains("com.docker.compose.project=aai1058") == true)
    }

    /// Every remedy shows the literal command. A remedy the user cannot read
    /// is a remedy they cannot trust.
    @Test("every remedy carries a non-empty command preview")
    func everyRemedyShowsItsCommand() {
        for missing in [true, false] {
            for remedy in ThrallRemedy.remedies(for: incident(),
                                                stack: stack(configMissing: missing)) {
                #expect(!remedy.commandPreview.isEmpty, Comment(rawValue: remedy.title))
                #expect(!remedy.title.isEmpty)
            }
        }
    }

    /// With no dependency verdict the evidence points at the image, so
    /// re-pulling becomes worth offering — and the dependency remedy must not
    /// be invented.
    @Test("with no dependency verdict, pull is offered and no dependency remedy is invented")
    func noVerdictOffersPull() {
        let remedies = ThrallRemedy.remedies(for: incident(dependency: nil),
                                             stack: stack(configMissing: false))
        #expect(!remedies.contains { if case .restartDependencyThenDependents = $0.kind {
            return true } else { return false } })
        #expect(remedies.contains { $0.kind == .pullStack })
    }

    @Test("a missing stack still yields usable remedies")
    func noStack() {
        #expect(!ThrallRemedy.remedies(for: incident(), stack: nil).isEmpty)
    }
}

@Suite("ThrallStreamSupervisor backoff")
struct ThrallStreamSupervisorTests {
    /// 250 ms doubling to a 30 s ceiling.
    @Test("backoff grows and is capped")
    func backoffGrowsAndCaps() {
        let first = ThrallStreamSupervisor.backoff(attempt: 1)
        let later = ThrallStreamSupervisor.backoff(attempt: 12)
        #expect(first < .seconds(1))
        #expect(later <= .seconds(40))
        #expect(later > .seconds(15))
    }

    /// **The jitter is not decoration.** Without it every Thrall window on the
    /// machine retries in lockstep after an engine restart and hammers the
    /// socket together at the moment it is least able to answer.
    @Test("backoff is jittered, so windows do not retry in lockstep")
    func backoffIsJittered() {
        let samples = (0..<40).map { _ in ThrallStreamSupervisor.backoff(attempt: 6) }
        #expect(Set(samples).count > 1)
    }

    /// Unfiltered, this machine produced 256 events in an hour and every one
    /// was a healthcheck exec. The filter is what keeps the socket quiet.
    @Test("the event filter asks for container lifecycle only")
    func filterExcludesExecNoise() {
        let filters = ThrallStreamSupervisor.eventFilters
        #expect(filters.contains("\"type\":[\"container\"]"))
        #expect(filters.contains("\"die\""))
        #expect(!filters.contains("exec_"))
        #expect(!filters.contains("health_status"))
        // And it survives being put in a URL, which `ThrallHTTPRequest` will
        // otherwise refuse.
        let target = ThrallEngineClient.target("/v1.51/events", query: [("filters", filters)])
        #expect(throws: Never.self) { try ThrallHTTPRequest(target: target).encoded() }
    }
}
