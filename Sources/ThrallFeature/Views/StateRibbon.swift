import SwiftUI
import AinkradAppKit

/// A stack's container states as one proportional bar.
///
/// **Local to Thrall on purpose.** `AinkradStatusBar` is single-value — it
/// quantises one ratio into 12 segments — and a stack row needs to say
/// "19 running, 28 exited, 1 created" in one glance. A multi-run bar is
/// proposed as `AinkradStackedStatusBar` at the report; until that is
/// accepted, it lives here rather than deviating from the design system by
/// bending a component to a shape it does not have.
///
/// Colours come from `\.ainkradStatusColors` through `AinkradStatus`, never
/// hardcoded, so it follows the host theme like everything else.
struct StateRibbon: View {
    let breakdown: ThrallStateBreakdown

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    /// Severity order, worst last, so the eye lands on the problem end.
    private var runs: [(count: Int, status: AinkradStatus)] {
        [
            (breakdown.running, .success),
            (breakdown.created, .neutral),
            (breakdown.paused, .neutral),
            (breakdown.other, .neutral),
            (breakdown.exited, .warning),
            (breakdown.restarting, .danger),
            (breakdown.dead, .danger),
        ].filter { $0.0 > 0 }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    Rectangle()
                        .fill(run.status.color(in: theme, statusColors: statusColors))
                        .frame(width: width(for: run.count, in: geometry.size.width))
                }
            }
        }
        .frame(width: 64, height: 4)
        .clipShape(Capsule())
        // An empty stack still draws its track, so the row's geometry does not
        // change when the last container goes away.
        .background(Capsule().fill(theme.foreground.opacity(0.12)))
    }

    private func width(for count: Int, in total: CGFloat) -> CGFloat {
        guard breakdown.total > 0 else { return 0 }
        let share = CGFloat(count) / CGFloat(breakdown.total)
        // A minimum of 2pt so a single exited container in a stack of 24 is
        // still visible — which is the case this whole component exists for.
        return max(2, (total - CGFloat(max(0, runs.count - 1))) * share)
    }
}
