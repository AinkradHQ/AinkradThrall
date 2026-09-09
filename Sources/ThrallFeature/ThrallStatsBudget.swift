import Foundation
import AinkradAppKit

/// How often Thrall may sample live container stats, and how many at a time.
///
/// A pure first-match table mirroring `AinkradMotionBudget`, and the numbers
/// are the point:
///
/// | condition | interval |
/// |---|---|
/// | window hidden | **never** — sockets closed |
/// | low power | 10 s |
/// | app inactive | 5 s |
/// | active | 2 s |
///
/// **Never open one stats stream per container.** `/containers/{id}/stats`
/// held open for 48 containers is 48 permanent sockets waking the CPU
/// continuously — which is the Docker Desktop battery complaint, reproduced
/// exactly. `?stream=false&one-shot=true` works, so Thrall sweeps instead,
/// capped to the containers actually on screen and at most `maxConcurrent` at
/// a time: about six requests at peak rather than 48 forever.
public struct ThrallStatsBudget: Equatable, Sendable {
    /// Nil means "do not sample at all", which is the hidden-window case.
    public let interval: Double?
    public let maxConcurrent: Int

    public static let maximumConcurrentSamples = 4

    public init(interval: Double?, maxConcurrent: Int = maximumConcurrentSamples) {
        self.interval = interval
        self.maxConcurrent = maxConcurrent
    }

    /// First match wins, so the order of these branches is the policy.
    public static func resolve(_ budget: AinkradMotionBudget) -> ThrallStatsBudget {
        // Hidden first and unconditionally: an invisible window sampling
        // anything is pure waste, and closing the sockets is what makes the
        // difference measurable.
        if !budget.isWindowVisible { return ThrallStatsBudget(interval: nil) }
        if budget.isLowPower { return ThrallStatsBudget(interval: 10) }
        if !budget.isAppActive { return ThrallStatsBudget(interval: 5) }
        return ThrallStatsBudget(interval: 2)
    }

    public var isSampling: Bool { interval != nil }

    /// The containers worth sampling: **on screen and running**.
    ///
    /// Sampling a stopped container returns zeros forever, so it costs a
    /// request to learn nothing — and with 28 of the 48 containers here
    /// exited, that is most of them.
    public static func sampleSet(visible: [ThrallContainer]) -> [String] {
        visible.filter { $0.state == .running }.map(\.id)
    }
}
