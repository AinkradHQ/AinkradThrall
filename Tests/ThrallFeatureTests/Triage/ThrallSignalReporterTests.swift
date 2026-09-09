import Foundation
import Testing
import AinkradAppKit
@testable import ThrallFeature

/// Records what was emitted, so the three suppression gates can be asserted
/// rather than trusted.
@MainActor
final class RecordingSignalEmitter: PluginSignalEmitter {
    struct Emitted: Equatable {
        let kind: String
        let severity: SignalSeverity
        let title: String
        let importance: SignalImportance
        let dedupeKey: String?
    }
    var emitted: [Emitted] = []

    func emit(kind: String, severity: SignalSeverity, title: String, body: String?,
              importance: SignalImportance, deepLink: SignalDeepLink?,
              actions: [SignalAction], dedupeKey: String?) {
        emitted.append(Emitted(kind: kind, severity: severity, title: title,
                               importance: importance, dedupeKey: dedupeKey))
    }
    func own(limit: Int) -> [SignalEvent] { [] }
    func handleAction(_ actionID: String,
                      _ handler: @escaping @MainActor () async -> Void) -> AgentActionToken {
        AgentActionToken()
    }
    func removeActionHandler(_ token: AgentActionToken) {}
}

/// **Signal spam would kill this feature permanently**, so every gate gets a
/// test rather than a comment.
@MainActor
@Suite("ThrallSignalReporter")
struct ThrallSignalReporterTests {
    private static let stackID = ThrallStackID(engineKey: "e", projectName: "aai1058",
                                                workingDirectory: ThrallPathKey("/tmp/wt"))

    private func incident(_ fingerprint: String, services: [String] = ["worker"],
                          stack: ThrallStackID = stackID) -> ThrallIncident {
        ThrallIncident(key: .init(stack: stack, fingerprint: fingerprint),
                       stackName: "aai1058", services: services,
                       containerIDs: services.map { "c-\($0)" }, exitCode: 1,
                       evidence: "Connection refused", imageDigest: "sha256:a",
                       firstSeen: Date(timeIntervalSince1970: 1),
                       lastSeen: Date(timeIntervalSince1970: 2),
                       restartTotal: 7, brokenDependencies: [])
    }

    /// **Gate 3.** Opening Thrall on the machine the plan was written against
    /// would otherwise have fired 15 urgent notifications at once.
    @Test("the first scan seeds a baseline and emits nothing")
    func firstScanIsSilent() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: (1...15).map { incident("f\($0)") },
                        suppressedStacks: [], to: emitter)
        #expect(emitter.emitted.isEmpty)
    }

    @Test("a new incident after the baseline emits once, urgently")
    func newIncidentEmitsOnce() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        reporter.report(incidents: [incident("f1")], suppressedStacks: [], to: emitter)
        #expect(emitter.emitted.count == 1)
        #expect(emitter.emitted[0].severity == .failure)
        #expect(emitter.emitted[0].importance == .urgent)
        #expect(emitter.emitted[0].kind == "thrall.crashloop")
    }

    /// **Deduped per service, not per container.** Compose mints a new
    /// container id on every recreate, so a container-keyed dedupe emits
    /// unbounded urgent notifications for one broken service.
    @Test("re-reporting the same incident is silent, across ten scans")
    func repeatScansAreSilent() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        for _ in 0..<10 {
            reporter.report(incidents: [incident("f1")], suppressedStacks: [], to: emitter)
        }
        #expect(emitter.emitted.filter { $0.kind == "thrall.crashloop" }.count == 1)
    }

    /// **Gate 2.** `docker compose up` emits a `die` per recreated container,
    /// so without the settle window the user's own Restart button fires a
    /// crash-loop alert per service — which would happen in the first demo.
    @Test("a stack inside its settle window emits nothing")
    func settleWindowSuppresses() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        reporter.report(incidents: [incident("f1"), incident("f2")],
                        suppressedStacks: [Self.stackID], to: emitter)
        #expect(emitter.emitted.isEmpty)
    }

    /// A settling stack is not cleared either: announcing a recovery the
    /// instant the user pressed Restart would be a lie.
    @Test("a settling stack is neither emitted nor cleared")
    func settleWindowAlsoSuppressesClears() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        reporter.report(incidents: [incident("f1")], suppressedStacks: [], to: emitter)
        emitter.emitted.removeAll()
        // The user hits Restart; the incident vanishes mid-recreate.
        reporter.report(incidents: [], suppressedStacks: [Self.stackID], to: emitter)
        #expect(emitter.emitted.isEmpty)
        // And once it is genuinely gone, the clear does arrive.
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        #expect(emitter.emitted.map(\.severity) == [.success])
    }

    /// **The "it's fixed" row is what makes the feed trustworthy.** A feed
    /// that only accumulates failures teaches the user to ignore it.
    @Test("a resolved incident emits a success clear, naming what recovered")
    func clearOnResolution() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        reporter.report(incidents: [incident("f1", services: ["worker"])],
                        suppressedStacks: [], to: emitter)
        emitter.emitted.removeAll()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)

        #expect(emitter.emitted.count == 1)
        #expect(emitter.emitted[0].severity == .success)
        #expect(emitter.emitted[0].kind == "thrall.crashloop.cleared")
        #expect(emitter.emitted[0].title.contains("worker"))
    }

    @Test("a clear is emitted once, not on every subsequent scan")
    func clearEmitsOnce() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        reporter.report(incidents: [incident("f1")], suppressedStacks: [], to: emitter)
        for _ in 0..<5 { reporter.report(incidents: [], suppressedStacks: [], to: emitter) }
        #expect(emitter.emitted.filter { $0.severity == .success }.count == 1)
    }

    /// The dedupe key is the incident id, which is `(stack, fingerprint)` and
    /// therefore stable across container recreates by construction.
    @Test("the dedupe key is the incident identity")
    func dedupeKeyIsTheIncident() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        let target = incident("f1")
        reporter.report(incidents: [target], suppressedStacks: [], to: emitter)
        #expect(emitter.emitted[0].dedupeKey == target.id)
    }

    /// Switching engines must not announce every incident on the old one as
    /// recovered.
    @Test("reset does not emit a flood of clears")
    func resetIsSilent() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        reporter.report(incidents: (1...5).map { incident("f\($0)") },
                        suppressedStacks: [], to: emitter)
        emitter.emitted.removeAll()
        reporter.reset()
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        #expect(emitter.emitted.isEmpty, "reset re-seeds the baseline rather than clearing")
    }

    @Test("two different stacks each get their own signal")
    func perStackSignals() {
        let emitter = RecordingSignalEmitter()
        let reporter = ThrallSignalReporter()
        let other = ThrallStackID(engineKey: "e", projectName: "optimus",
                                  workingDirectory: ThrallPathKey("/tmp/o"))
        reporter.report(incidents: [], suppressedStacks: [], to: emitter)
        reporter.report(incidents: [incident("f1"), incident("f1", stack: other)],
                        suppressedStacks: [], to: emitter)
        #expect(emitter.emitted.count == 2)
        #expect(Set(emitter.emitted.compactMap(\.dedupeKey)).count == 2)
    }
}
