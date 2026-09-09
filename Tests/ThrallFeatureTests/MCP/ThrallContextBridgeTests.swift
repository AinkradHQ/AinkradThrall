import Foundation
import Testing
@testable import ThrallFeature

@MainActor
@Suite("ThrallContextBridge")
struct ThrallContextBridgeTests {
    /// The host truncates each context source at 8000 characters and does so
    /// **mid-string**, so a brief that overruns loses its tail in the middle
    /// of a sentence — which reads to a model as corrupted input rather than
    /// an omission.
    @Test("the budget stays under the host's per-source limit")
    func budgetIsUnderHostLimit() {
        // AgentContextService.perSourceCharBudget, read from the host source.
        #expect(ThrallContextBridge.characterBudget < 8_000)
    }

    @Test("clamping cuts on a line boundary and says that it did")
    func clampIsHonest() {
        let long = (1...2_000).map { "line \($0) of a very long brief" }
            .joined(separator: "\n")
        let clamped = ThrallContextBridge.clamp(long)
        #expect(clamped.count <= ThrallContextBridge.characterBudget)
        #expect(clamped.contains("brief truncated"))
        #expect(clamped.contains("thrall_diagnose"))
        // Cut on a boundary: no half-written line survives.
        let lines = clamped.split(separator: "\n").map(String.init)
        let content = lines.filter { $0.hasPrefix("line ") }
        #expect(content.allSatisfy { $0.hasSuffix("very long brief") })
    }

    @Test("short text is returned unchanged")
    func shortTextUntouched() {
        #expect(ThrallContextBridge.clamp("two\nlines") == "two\nlines")
    }

    /// The host's privacy opt-out is keyed on `kind`, so it has to be a stable
    /// string or a user's "off" silently stops applying.
    @Test("the context kind is stable and namespaced")
    func kindIsStable() {
        #expect(ThrallContextBridge.kind == "thrall")
    }

    /// Returning an empty section every turn would spend prompt budget to tell
    /// the assistant nothing.
    @Test("no source means no snapshot")
    func noSourceNoSnapshot() {
        #expect(ThrallContextBridge().snapshot() == nil)
    }

    /// A truncated list of everything is worse than a complete list of the
    /// three things that matter.
    @Test("only a few incidents are described in full")
    func detailLimitIsSmall() {
        #expect(ThrallContextBridge.detailedIncidentLimit <= 3)
    }
}
