import AinkradAppKit
import Testing

@testable import ThrallFeature

@Suite("ThrallContainerState.status")
struct ContainerStateStatusTests {
    @Test("one mapping for every site: dead and restarting are danger")
    func mapping() {
        #expect(ThrallContainerState.running.status == .success)
        #expect(ThrallContainerState.restarting.status == .danger)
        #expect(ThrallContainerState.dead.status == .danger)
        #expect(ThrallContainerState.exited.status == .warning)
        #expect(ThrallContainerState.unknown("x").status == .warning)
        #expect(ThrallContainerState.created.status == .neutral)
        #expect(ThrallContainerState.paused.status == .neutral)
    }
}
