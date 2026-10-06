import Foundation
import Testing

@testable import ThrallFeature

@Suite("ThrallDependency")
struct ThrallDependencyTests {
    @Test("parses the label compose actually writes")
    func parsesRealLabel() {
        let parsed = ThrallDependency.parse(
            label: "redis:service_started:false,mysql:service_healthy:true")
        #expect(parsed.count == 2)
        #expect(
            parsed[0]
                == ThrallDependency(
                    service: "redis", condition: "service_started",
                    restartsDependents: false))
        #expect(parsed[1].restartsDependents)
    }

    /// A bad label must never cost the user a row.
    @Test(
        "malformed clauses are dropped, not thrown",
        arguments: ["", "redis", "redis:only-two", ":empty:false", "a:b:c:d"])
    func dropsMalformed(label: String) {
        #expect(ThrallDependency.parse(label: label).isEmpty)
    }

    @Test("a good clause survives beside a bad one")
    func mixedLabel() {
        #expect(ThrallDependency.parse(label: "broken,db:service_healthy:false").count == 1)
    }
}
