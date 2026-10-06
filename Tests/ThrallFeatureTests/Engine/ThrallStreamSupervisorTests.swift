import Foundation
import Testing

@testable import ThrallFeature

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
