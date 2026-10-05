import Foundation
import Testing

@testable import ThrallFeature

@MainActor
@Suite("ThrallMCPWriteTools restart and down")
struct ThrallMCPWriteToolsTests {
    private func container(_ id: String) -> ThrallContainer {
        ThrallContainer(
            id: id, name: id, image: "img", state: .running, statusText: "Up",
            created: Date(timeIntervalSince1970: 0), replicaNumber: 1, isOneOff: false)
    }

    private func stack() -> ThrallStack {
        ThrallStack(
            id: ThrallStackID(
                engineKey: "e", projectName: "shop", workingDirectory: ThrallPathKey("/tmp/shop")),
            displayName: "shop", workingDirectoryDisplay: "/tmp/shop",
            configFiles: ["/tmp/shop/compose.yml"], absentConfigFiles: [],
            services: [
                ThrallService(
                    name: "db", containers: [container("c-db")], dependsOn: [],
                    isDeclaredButAbsent: false),
                ThrallService(
                    name: "api", containers: [container("c-api")], dependsOn: [],
                    isDeclaredButAbsent: false),
            ],
            breakdown: ThrallStateBreakdown(), health: .allRunning, isStaleRelativeToConfig: false)
    }

    @Test("restart passes the named service through to compose")
    func restartHonoursService() throws {
        let stack = stack()
        guard case .success(let names) = ThrallMCPWriteTools.requestedServices(
            ["stack": "shop", "service": "db"], in: stack)
        else {
            Issue.record("a known service must be accepted")
            return
        }
        let command = try #require(
            ThrallViewModel.composeCommand(.restart, on: stack, services: names))
        let arguments = try command.arguments()
        #expect(Array(arguments.suffix(3)) == ["restart", "--", "db"])
    }

    @Test("restart without a service still targets the whole stack")
    func restartWholeStack() throws {
        let stack = stack()
        let command = try #require(
            ThrallViewModel.composeCommand(.restart, on: stack, services: []))
        #expect(try command.arguments().last == "restart")
    }

    @Test("the engine path restarts only the named service's containers")
    func engineTargetsHonourService() {
        let stack = stack()
        #expect(ThrallViewModel.engineTargets(in: stack, services: ["api"]).map(\.id) == ["c-api"])
        #expect(ThrallViewModel.engineTargets(in: stack, services: []).count == 2)
    }

    @Test("an unknown service is refused, not widened to the whole stack")
    func unknownServiceRefused() {
        let result = ThrallMCPWriteTools.requestedServices(
            ["stack": "shop", "service": "nope"], in: stack())
        guard case .failure(let error) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.message.contains("db, api"))
    }

    /// `perform(.down)` only sets `pendingDown` when confirmation is on; saying
    /// the stack is going down then is a report of something that did not happen.
    @Test("down reports confirmation pending when only pendingDown was set")
    func downPending() {
        let pending = ThrallMCPWriteTools.downResult(for: stack(), confirmationPending: true)
        #expect(pending.text.contains("Confirmation pending"))
        #expect(!pending.text.hasPrefix("Taking"))
        let done = ThrallMCPWriteTools.downResult(for: stack(), confirmationPending: false)
        #expect(done.text.hasPrefix("Taking shop down"))
    }
}
