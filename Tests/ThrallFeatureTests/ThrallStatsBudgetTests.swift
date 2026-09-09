import Foundation
import Testing
import AinkradAppKit
@testable import ThrallFeature

/// The battery policy, as a table. Every branch here is a number a reviewer
/// can argue with, which is the point of it being pure.
@Suite("ThrallStatsBudget")
struct ThrallStatsBudgetTests {
    private func budget(active: Bool = true, visible: Bool = true,
                        lowPower: Bool = false) -> AinkradMotionBudget {
        AinkradMotionBudget(isAppActive: active, isWindowVisible: visible,
                            isLowPower: lowPower, reduceMotion: false)
    }

    /// An invisible window sampling anything is pure waste, and closing the
    /// sockets is what makes the difference measurable.
    @Test("a hidden window stops sampling entirely")
    func hiddenStopsEverything() {
        let resolved = ThrallStatsBudget.resolve(budget(visible: false))
        #expect(resolved.interval == nil)
        #expect(!resolved.isSampling)
    }

    /// Hidden wins over every other condition, so the branch order is part of
    /// the policy rather than an accident.
    @Test("hidden beats active and low power")
    func hiddenWinsFirst() {
        #expect(ThrallStatsBudget.resolve(
            budget(active: true, visible: false, lowPower: false)).interval == nil)
        #expect(ThrallStatsBudget.resolve(
            budget(active: true, visible: false, lowPower: true)).interval == nil)
    }

    @Test("the intervals match the declared table", arguments: [
        (true, true, false, 2.0),
        (false, true, false, 5.0),
        (true, true, true, 10.0),
        (false, true, true, 10.0),
    ])
    func intervals(active: Bool, visible: Bool, lowPower: Bool, expected: Double) {
        #expect(ThrallStatsBudget.resolve(
            budget(active: active, visible: visible, lowPower: lowPower)).interval == expected)
    }

    @Test("the frozen and full budgets resolve sensibly")
    func kitBudgets() {
        #expect(!ThrallStatsBudget.resolve(.frozen).isSampling)
        #expect(ThrallStatsBudget.resolve(.full).interval == 2)
    }

    /// **Never one stream per container.** 48 held-open stats sockets is the
    /// Docker Desktop battery complaint reproduced exactly.
    @Test("concurrency is capped well below the container count")
    func concurrencyIsCapped() {
        #expect(ThrallStatsBudget.maximumConcurrentSamples == 4)
        #expect(ThrallStatsBudget.resolve(.full).maxConcurrent == 4)
    }

    /// Sampling a stopped container returns zeros forever — a request to learn
    /// nothing. 28 of the 48 containers here are exited.
    @Test("only running containers are sampled")
    func onlyRunningIsSampled() {
        func container(_ id: String, _ state: ThrallContainerState) -> ThrallContainer {
            ThrallContainer(id: id, name: id, image: "x", state: state, statusText: "",
                            created: Date(), replicaNumber: nil, isOneOff: false)
        }
        let set = ThrallStatsBudget.sampleSet(visible: [
            container("a", .running), container("b", .exited), container("c", .restarting),
            container("d", .running), container("e", .created), container("f", .dead),
        ])
        #expect(set == ["a", "d"])
    }

    @Test("an empty screen samples nothing")
    func emptyScreen() {
        #expect(ThrallStatsBudget.sampleSet(visible: []).isEmpty)
    }
}
