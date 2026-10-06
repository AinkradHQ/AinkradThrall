import AinkradAppKit
import SwiftUI

/// The triage surface: what is wrong, why, and what to do about it.
struct TriageView: View {
    @ObservedObject var model: ThrallViewModel
    @ObservedObject var triage: ThrallTriageModel

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if triage.incidents.isEmpty {
                clearState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.md) {
                        ForEach(triage.incidents) { incident in
                            IncidentCard(
                                incident: incident,
                                stack: model.world.stack(incident.key.stack),
                                isBusy: model.busyStacks.contains(incident.key.stack),
                                onRemedy: { model.apply($0, to: incident) })
                        }
                    }
                    .padding(AinkradSpacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The empty state is a feature, not a placeholder. A triage feed is only
    /// trustworthy if "nothing is wrong" is stated as confidently as a
    /// failure — otherwise the user cannot tell it apart from "not scanned".
    private var clearState: some View {
        VStack(spacing: AinkradSpacing.sm) {
            AinkradEmptyState(
                icon: triage.hasBaseline ? "checkmark.circle" : "clock.arrow.circlepath",
                title: triage.hasBaseline ? "Nothing is crash-looping" : "Scanning…",
                message: triage.hasBaseline
                    ? "\(model.world.stacks.count) stacks checked on \(model.engineLabel). "
                        + "Thrall watches the engine's event stream and will say so here."
                    : "Reading restart counts and recent deaths.")
            if let scan = triage.lastScan, triage.hasBaseline {
                Text("Last checked \(scan.formatted(date: .omitted, time: .standard))")
                    .font(skin.font(AinkradFontToken(sizeKey: "t10", monospacedDigits: true)))
                    .foregroundStyle(theme.foreground.opacity(skin.opacity.o40))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IncidentCard: View {
    let incident: ThrallIncident
    let stack: ThrallStack?
    let isBusy: Bool
    let onRemedy: (ThrallRemedy) -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradStatusColors) private var statusColors
    @Environment(\.ainkradReduceMotion) private var reduceMotion
    @State private var showsAllRemedies = false

    var body: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                header
                if let verdict = incident.brokenDependencies.first {
                    verdictBanner(verdict)
                }
                if let evidence = incident.evidence {
                    evidenceBlock(evidence)
                }
                members
                remedies
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AinkradSpacing.sm) {
            // The crash pulse — one of exactly two decorative uses of a
            // timeline in this app.
            BudgetedTimelineView { date in
                Circle()
                    .fill(AinkradStatus.danger.color(in: theme, statusColors: statusColors))
                    .frame(width: skin.size.s8, height: skin.size.s8)
                    .opacity(
                        reduceMotion
                            ? 1
                            : spinnerPulseOpacity(
                                date: date,
                                period: 1.4))  // design-lint: allow motion-literal token-gap motion.durations.d1_4
            }
            .frame(width: skin.size.s8, height: skin.size.s8)

            VStack(alignment: .leading, spacing: skin.size.s2) {
                Text(incident.headline)
                    .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
                Text("\(incident.stackName)  ·  \(incident.restartTotal) restarts")
                    .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                    .foregroundStyle(skin.color(skin.text.muted))
            }
            Spacer(minLength: 0)
            if isBusy { AinkradSpinner(size: skin.size.s14) }
            if let exitCode = incident.exitCode {
                AinkradBadge(text: "exit \(exitCode)", status: .danger)
            }
            AinkradBadge(text: "\(incident.memberCount) affected", status: .warning)
        }
    }

    /// "`api` depends_on `db`; `db` is `exited`" — the answer, stated as a
    /// banner rather than left for the user to infer from a list of red rows.
    private func verdictBanner(_ verdict: ThrallDependencyVerdict) -> some View {
        AinkradBanner(
            message: "\(verdict.dependent) depends_on \(verdict.dependency) "
                + "(\(verdict.condition)) — \(verdict.dependency) is \(verdict.stateLabel)",
            status: .warning)
    }

    /// **The actual error text, never a paraphrase.** A summary the user
    /// cannot check against their own logs is worse than no summary.
    private func evidenceBlock(_ evidence: String) -> some View {
        AinkradCodeBlock(evidence)
    }

    private var members: some View {
        Text(incident.services.joined(separator: ", "))
            .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
            .foregroundStyle(theme.foreground.opacity(skin.opacity.o60))
            .lineLimit(2)
            .truncationMode(.tail)
    }

    /// Ordered by decreasing confidence, each showing the exact command
    /// before it runs. Only the first is shown until asked — a wall of
    /// equally-weighted options is not advice.
    private var remedies: some View {
        let all = ThrallRemedy.remedies(for: incident, stack: stack)
        let shown = showsAllRemedies ? all : Array(all.prefix(1))
        return VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            ForEach(shown) { remedy in
                RemedyRow(
                    remedy: remedy, isPrimary: remedy == all.first,
                    onRun: { onRemedy(remedy) })
            }
            if all.count > 1 {
                AinkradButton(
                    title: showsAllRemedies
                        ? "Fewer options"
                        : "\(all.count - 1) other option\(all.count == 2 ? "" : "s")",
                    style: .ghost
                ) {
                    withAnimation(reduceMotion ? nil : AinkradMotion.present) {
                        showsAllRemedies.toggle()
                    }
                }
            }
        }
    }
}

private struct RemedyRow: View {
    let remedy: ThrallRemedy
    let isPrimary: Bool
    let onRun: () -> Void

    @State private var showsCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradButton(
                    title: remedy.title,
                    style: isPrimary ? .primary : .secondary,
                    action: onRun)
                AinkradButton(title: showsCommand ? "Hide command" : "Show command", style: .ghost) {
                    showsCommand.toggle()
                }
                if remedy.destroysState {
                    AinkradBadge(text: "Destroys state", status: .danger)
                }
                Spacer(minLength: 0)
            }
            if showsCommand {
                AinkradCodeBlock(remedy.commandPreview)
            }
        }
    }
}
