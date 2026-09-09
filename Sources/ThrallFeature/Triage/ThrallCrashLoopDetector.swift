import Foundation

/// Why a service is considered to be crash-looping.
public enum ThrallCrashLoopEvidence: Equatable, Sendable {
    /// Counted from `/events` this session: N deaths with the same nonzero
    /// exit code inside the window. The good signal — it can say
    /// "restarting x7, exit 1".
    case observedDeaths(count: Int, exitCode: Int, window: TimeInterval)
    /// Inferred at cold start from `RestartCount`, which has no timestamps.
    /// Weaker, and gated hard — see the detector's documentation.
    case restartCount(Int, since: Date)
}

public struct ThrallCrashLoop: Equatable, Sendable {
    public let stack: ThrallStackID
    public let service: String
    public let evidence: ThrallCrashLoopEvidence
    public let exitCode: Int?
    public let containerIDs: [String]

    public var restartCount: Int {
        switch evidence {
        case .observedDeaths(let count, _, _): return count
        case .restartCount(let count, _): return count
        }
    }
}

/// Decides whether a service is crash-looping.
///
/// Two derivations, because the two situations have different evidence:
///
/// **Warm** — `>= 3` deaths with the same nonzero exit code inside 120 s, from
/// `/events` recorded this session. This is the good signal, and the only one
/// that can say "restarting x7, exit 1".
///
/// **Cold start** — no event history yet, so `RestartCount` from `inspect` is
/// all there is. It is **lifetime-cumulative**, so without a recency clause
/// every long-lived container on a laptop that sleeps looks like a crash loop
/// and the plugin becomes a spam source on first launch. The clause is that
/// the container must have *finished* recently: an old `RestartCount` on a
/// container that has been up for days is history, not a problem.
///
/// **`RestartPolicy == "no"` is checked first, and it is not an optimisation.**
/// A container the engine will not restart cannot be in a *loop* — it exited
/// once. Without this check, every one-shot migration job that exits nonzero
/// (`laravel-migrate`, `desking-migrate` on this machine) is reported as a
/// crash loop forever.
public enum ThrallCrashLoopDetector {
    /// Deaths needed inside the window. Below 3, an ordinary restart or a
    /// `compose up` recreate would qualify.
    public static let deathThreshold = 3
    public static let window: TimeInterval = 120
    /// How recently a container must have died for `RestartCount` to mean
    /// anything. Generous, because a cold start may be hours after the fact,
    /// but finite, because that is the whole point of the clause.
    public static let restartCountRecency: TimeInterval = 15 * 60
    /// A cumulative count below this is normal operation over a long uptime.
    public static let restartCountThreshold = 3

    /// One service's inputs. Kept as a struct so the detector stays a pure
    /// function over data a test can state.
    public struct Candidate: Equatable, Sendable {
        public let stack: ThrallStackID
        public let service: String
        public let containers: [ThrallContainer]
        /// From `inspect`, per container id.
        public let restartCounts: [String: Int]
        public let restartPolicies: [String: Bool]
        public let finishedAt: [String: Date]

        public init(stack: ThrallStackID, service: String, containers: [ThrallContainer],
                    restartCounts: [String: Int] = [:],
                    restartPolicies: [String: Bool] = [:],
                    finishedAt: [String: Date] = [:]) {
            self.stack = stack
            self.service = service
            self.containers = containers
            self.restartCounts = restartCounts
            self.restartPolicies = restartPolicies
            self.finishedAt = finishedAt
        }
    }

    public static func detect(candidate: Candidate,
                              history: ThrallEventHistory,
                              now: Date) -> ThrallCrashLoop? {
        // Rule 0: a container the engine will not restart cannot loop.
        let restartable = candidate.containers.filter {
            candidate.restartPolicies[$0.id] ?? true
        }
        guard !restartable.isEmpty else { return nil }

        let key = ThrallEventHistory.ServiceKey(stack: candidate.stack, service: candidate.service)
        let recent = history.recentDeaths(for: key, since: now.addingTimeInterval(-window))
        // Warm: same nonzero exit code, at or over the threshold.
        let byExitCode = Dictionary(grouping: recent.filter { $0.exitCode != 0 }, by: \.exitCode)
        if let (exitCode, deaths) = byExitCode
            .filter({ $0.value.count >= deathThreshold })
            .max(by: { $0.value.count < $1.value.count }) {
            return ThrallCrashLoop(
                stack: candidate.stack,
                service: candidate.service,
                evidence: .observedDeaths(count: deaths.count, exitCode: exitCode, window: window),
                exitCode: exitCode,
                containerIDs: deaths.map(\.containerID).uniqued())
        }

        // Cold: RestartCount, with the recency clause.
        guard recent.isEmpty else { return nil }
        for container in restartable {
            let count = candidate.restartCounts[container.id] ?? 0
            guard count >= restartCountThreshold else { continue }
            guard let finished = candidate.finishedAt[container.id],
                  now.timeIntervalSince(finished) <= restartCountRecency else { continue }
            return ThrallCrashLoop(
                stack: candidate.stack,
                service: candidate.service,
                evidence: .restartCount(count, since: finished),
                exitCode: nil,
                containerIDs: [container.id])
        }
        return nil
    }

    /// Runs the detector over a whole world.
    public static func detectAll(candidates: [Candidate],
                                 history: ThrallEventHistory,
                                 now: Date) -> [ThrallCrashLoop] {
        candidates.compactMap { detect(candidate: $0, history: history, now: now) }
            // Ordered by identity, not by severity: the triage list must not
            // reshuffle as counts tick up.
            .sorted { ($0.stack.description, $0.service) < ($1.stack.description, $1.service) }
    }
}

extension Array where Element: Hashable {
    /// Order-preserving dedupe.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
