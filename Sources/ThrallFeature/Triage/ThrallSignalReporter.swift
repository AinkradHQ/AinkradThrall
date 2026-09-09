import Foundation
import AinkradAppKit

/// Emits one signal per incident, and a `.success` when it clears.
///
/// ## Signal spam would kill this feature permanently, so all three gates are
/// mandatory
///
///  1. **The >=3 threshold**, in the detector. Below it, an ordinary restart or
///     a `compose up` recreate would emit.
///  2. **A 30 s settle window after any user action.** `docker compose up`
///     emits a `die` for every container it recreates, so without this the
///     user pressing Restart fires a crash-loop alert per service — which
///     would happen in the very first demo. Applied by the caller, which is
///     the only thing that knows when the user acted.
///  3. **First-scan suppression.** The opening scan seeds a baseline and emits
///     nothing. Without it, opening Thrall on this machine at the time the
///     plan was written would have fired 15 urgent notifications at once.
///
/// ## Deduped per service, not per container
///
/// Compose mints a new container id on every recreate, so a container-keyed
/// dedupe emits unbounded `.urgent` notifications for one broken service. The
/// dedupe key is the incident's own id — `(stack, fingerprint)` — which is
/// stable across recreates by construction.
@MainActor
public final class ThrallSignalReporter {
    /// Incident ids currently reported, so a repeat scan is silent.
    private var reported: Set<String> = []
    /// Titles kept so a clear can name what recovered.
    private var titles: [String: String] = [:]
    private var hasBaseline = false

    public init() {}

    /// Diffs `incidents` against what has already been reported.
    ///
    /// - Parameters:
    ///   - suppressedStacks: stacks inside their settle window. Their
    ///     incidents are neither emitted **nor** cleared — a stack mid-restart
    ///     is not news in either direction.
    public func report(incidents: [ThrallIncident],
                       suppressedStacks: Set<ThrallStackID>,
                       to signals: any PluginSignalEmitter) {
        let visible = incidents.filter { !suppressedStacks.contains($0.key.stack) }
        let current = Set(visible.map(\.id))

        // Gate 3: the first scan only seeds.
        guard hasBaseline else {
            hasBaseline = true
            reported = current
            for incident in visible { titles[incident.id] = incident.headline }
            return
        }

        for incident in visible where !reported.contains(incident.id) {
            titles[incident.id] = incident.headline
            signals.emit(
                kind: "thrall.crashloop",
                severity: .failure,
                title: incident.headline,
                body: body(for: incident),
                // Urgent because a crash loop is happening now and the user's
                // work is blocked on it. The threshold and the two windows are
                // what make that honest.
                importance: .urgent,
                dedupeKey: incident.id)
        }

        // The "it's fixed" row is what makes the feed trustworthy: a feed that
        // only ever accumulates failures teaches the user to ignore it.
        for cleared in reported.subtracting(current) {
            // Not cleared while its stack is settling — that would announce a
            // recovery the moment the user pressed Restart, before anything
            // had actually recovered.
            guard !isSuppressed(cleared, in: suppressedStacks) else { continue }
            signals.emit(kind: "thrall.crashloop.cleared",
                         severity: .success,
                         title: "Recovered: \(titles[cleared] ?? "a crash loop")",
                         importance: .normal,
                         dedupeKey: cleared + ".cleared")
            titles[cleared] = nil
        }

        reported = current.union(reported.filter { isSuppressed($0, in: suppressedStacks) })
    }

    private func isSuppressed(_ incidentID: String, in stacks: Set<ThrallStackID>) -> Bool {
        stacks.contains { incidentID.hasPrefix($0.description + "#") }
    }

    private func body(for incident: ThrallIncident) -> String {
        var lines: [String] = []
        lines.append("\(incident.stackName) · \(incident.memberCount) container"
            + "\(incident.memberCount == 1 ? "" : "s") · \(incident.restartTotal) restarts")
        if let verdict = incident.brokenDependencies.first {
            lines.append("\(verdict.dependency) is \(verdict.stateLabel)")
        }
        // The engine's own words, truncated for a notification rather than
        // paraphrased.
        if let evidence = incident.evidence {
            lines.append(String(evidence.prefix(160)))
        }
        return lines.joined(separator: "\n")
    }

    /// Drops state for a torn-down engine, so switching context does not
    /// announce every incident as recovered.
    public func reset() {
        reported = []
        titles = [:]
        hasBaseline = false
    }
}
