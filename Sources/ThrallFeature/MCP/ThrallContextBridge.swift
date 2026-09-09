import Foundation
import AppKit
import AinkradAppKit

/// Publishes a read-only brief about what is broken, so that **with Thrall
/// open, Sage answers "why is api crash looping" with no handoff at all.**
///
/// That is the payoff of living inside an Agentic OS rather than being a
/// standalone app: the assistant already has the diagnosis in its prompt, so
/// the user does not have to describe their own machine to it.
///
/// ## Budget
///
/// The host truncates each context source at **8000 characters**
/// (`AgentContextService.perSourceCharBudget`) and does so mid-string, so a
/// brief that overruns loses its tail in the middle of a sentence. This one
/// targets ~4 KB and hard-caps below the host's limit, spending the space on
/// the worst incidents first — a truncated list of *everything* is worse than
/// a complete list of the three things that matter.
///
/// ## Privacy
///
/// The host's opt-out is keyed by `kind`, so the kind is a stable string the
/// user can switch off in Settings and have it stay off.
@MainActor
public final class ThrallContextBridge {
    /// Stable, because the host's per-kind privacy toggle is keyed on it.
    public static let kind = "thrall"
    /// Under the host's 8000-char budget with room to spare, so nothing is cut
    /// mid-sentence.
    static let characterBudget = 6_000
    /// Incidents described in full before the rest are merely counted.
    static let detailedIncidentLimit = 3

    private weak var model: ThrallViewModel?

    public init() {}

    public func setSource(_ model: ThrallViewModel) {
        self.model = model
    }

    public func clearSource(_ model: ThrallViewModel) {
        if self.model === model { self.model = nil }
    }

    /// Nil when there is nothing worth saying. Returning an empty section
    /// every turn would spend prompt budget to tell the assistant nothing.
    public func snapshot() -> AgentContextSnapshot? {
        guard let model, model.activeContext != nil else { return nil }
        let world = model.world
        guard !world.stacks.isEmpty else { return nil }
        return AgentContextSnapshot(kind: Self.kind,
                                    title: "Thrall — \(model.engineLabel)",
                                    text: brief(model: model))
    }

    /// The brief. Deliberately prose plus compact facts rather than JSON: this
    /// goes into a prompt, and the MCP tools already exist for when the
    /// assistant wants structure.
    func brief(model: ThrallViewModel) -> String {
        let world = model.world
        let incidents = model.triage.incidents
        var lines: [String] = []

        let running = world.stacks.reduce(0) { $0 + $1.breakdown.running }
        let total = world.stacks.reduce(0) { $0 + $1.containerCount }
        lines.append("Container engine: \(model.engineLabel)"
            + (model.engineVersion.map { " (API \($0.negotiated))" } ?? ""))
        lines.append("\(world.stacks.count) stacks, \(running)/\(total) containers running.")

        let orphaned = world.stacks.filter(\.isConfigMissing)
        if !orphaned.isEmpty {
            // Named explicitly because no other tool has a word for this, so
            // the assistant cannot be expected to infer it.
            lines.append("")
            lines.append("\(orphaned.count) stack\(orphaned.count == 1 ? "" : "s") "
                + "\(orphaned.count == 1 ? "is" : "are") running with no compose file on disk "
                + "(\(orphaned.map(\.displayName).joined(separator: ", "))). "
                + "docker compose cannot touch those — only engine-level container verbs, or "
                + "teardown by label.")
        }

        if incidents.isEmpty {
            lines.append("")
            lines.append("Nothing is crash-looping.")
        } else {
            lines.append("")
            lines.append("\(incidents.count) incident\(incidents.count == 1 ? "" : "s"):")
            for incident in incidents.prefix(Self.detailedIncidentLimit) {
                lines.append("")
                lines.append("- \(incident.headline)")
                lines.append("  stack: \(incident.stackName); services: "
                    + incident.services.joined(separator: ", "))
                if let exitCode = incident.exitCode {
                    lines.append("  exit code \(exitCode), \(incident.restartTotal) restarts")
                }
                if let verdict = incident.brokenDependencies.first {
                    lines.append("  \(verdict.dependent) depends_on \(verdict.dependency) "
                        + "(\(verdict.condition)); \(verdict.dependency) is \(verdict.stateLabel)")
                }
                if let evidence = incident.evidence {
                    // The **actual** error text. A paraphrase here is how an
                    // assistant ends up confidently describing a failure that
                    // did not happen.
                    lines.append("  error: \(evidence.prefix(300))")
                }
                if let remedy = ThrallRemedy.remedies(for: incident,
                                                       stack: world.stack(incident.key.stack))
                    .first {
                    lines.append("  best remedy: \(remedy.title)")
                }
            }
            if incidents.count > Self.detailedIncidentLimit {
                lines.append("")
                lines.append("\(incidents.count - Self.detailedIncidentLimit) further incidents "
                    + "are omitted here; call thrall_diagnose for all of them.")
            }
        }

        lines.append("")
        lines.append("Tools: thrall_diagnose, thrall_stacks, thrall_stack, thrall_logs, "
            + "thrall_restart_service, thrall_stack_up, thrall_stack_down, "
            + "thrall_stack_teardown.")

        return Self.clamp(lines.joined(separator: "\n"))
    }

    /// Truncates on a line boundary, and says that it did.
    ///
    /// The host would otherwise cut mid-word at 8000 characters, which reads
    /// to a model as corrupted input rather than an omission.
    static func clamp(_ text: String) -> String {
        guard text.count > characterBudget else { return text }
        var kept: [String] = []
        var used = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cost = line.count + 1
            if used + cost > characterBudget - 60 { break }
            kept.append(String(line))
            used += cost
        }
        kept.append("")
        kept.append("[brief truncated — call thrall_diagnose for the full picture]")
        return kept.joined(separator: "\n")
    }

    // MARK: - Handoff

    /// Hands the brief to Sage.
    ///
    /// **Verified against the host: Sage does not consume a
    /// `PluginAppLauncher` payload as a first turn.** Nothing in
    /// `Features/Sage` references `takePendingLaunch` — only `SignalReveal`
    /// and `HostAppLauncher` do. So the payload is sent anyway (it costs
    /// nothing and starts working the day Sage reads it) *and* the brief goes
    /// to the clipboard, which is the part that actually works today. The
    /// toast says so, because a button that silently does half of what it
    /// looks like is worse than one that explains itself.
    public func handOff(model: ThrallViewModel, host: HostServices) -> String {
        let text = brief(model: model)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        host.apps.open(appID: "sage", payload: text)
        return "Opened Sage. The brief is on your clipboard — paste it if Sage does not "
            + "already have it."
    }
}
