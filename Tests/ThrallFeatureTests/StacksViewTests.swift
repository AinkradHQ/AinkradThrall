import AinkradAppKit
import Testing

@testable import ThrallFeature

@Suite("StacksView")
struct StacksViewTests {
    @Test("statusRuns maps breakdown counts correctly to AinkradStatusRuns")
    func statusRunsMapping() {
        var breakdown = ThrallStateBreakdown()
        breakdown.add(.running)
        breakdown.add(.running)
        breakdown.add(.exited)
        breakdown.add(.dead)

        let runs = statusRuns(for: breakdown)
        #expect(
            runs == [
                AinkradStatusRun(count: 2, status: .success),
                AinkradStatusRun(count: 1, status: .warning),
                AinkradStatusRun(count: 1, status: .danger),
            ])
    }

    @Test("statusRuns keeps the breakdown's fixed state order and drops empty states")
    func statusRunsOrder() {
        var breakdown = ThrallStateBreakdown()
        for state in [.dead, .restarting, .exited, .removing, .paused, .created, .running] as [ThrallContainerState] {
            breakdown.add(state)
        }
        #expect(
            statusRuns(for: breakdown).map(\.status) == [
                ThrallContainerState.running, .created, .paused, .removing, .exited, .restarting, .dead,
            ].map(\.status))
        #expect(statusRuns(for: ThrallStateBreakdown()).isEmpty)
    }
}
