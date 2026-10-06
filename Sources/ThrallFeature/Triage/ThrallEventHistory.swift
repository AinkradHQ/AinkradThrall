import Foundation

/// A bounded history of container deaths, keyed **per compose service**.
///
/// ## Why we keep this at all
///
/// The daemon retains only minutes of events — a `since=` seven days back
/// returns the same few minutes — so there is no replay. If Thrall does not
/// persist the fact that a service died six times, nothing can.
///
/// ## Why per service and not per container
///
/// Compose assigns a **new container id on every recreate**. A
/// container-keyed history would show six containers that each died once
/// instead of one service that died six times, which is exactly the wrong
/// answer, and it is also why signals dedupe per service.
struct ThrallEventHistory: Equatable, Sendable {
    /// One death.
    struct Death: Equatable, Sendable {
        let containerID: String
        let exitCode: Int
        let at: Date

        init(containerID: String, exitCode: Int, at: Date) {
            self.containerID = containerID
            self.exitCode = exitCode
            self.at = at
        }
    }

    /// Identifies a service across recreates.
    struct ServiceKey: Hashable, Sendable {
        let stack: ThrallStackID
        let service: String

        init(stack: ThrallStackID, service: String) {
            self.stack = stack
            self.service = service
        }
    }

    /// Deaths retained per service, oldest first. Bounded because `/events`
    /// stays open for the whole session and a flapping service produces one
    /// entry every few seconds.
    let limitPerService: Int
    private(set) var deaths: [ServiceKey: [Death]] = [:]

    init(limitPerService: Int = 40) {
        self.limitPerService = limitPerService
    }

    /// Records a `die`. Anything else is ignored — including `exec_die`, which
    /// `ThrallEvent.parseAction` has already separated into `.exec`.
    mutating func record(_ event: ThrallEvent, engineKey: String) {
        guard event.isContainer, event.action == .die else { return }
        guard let service = event.composeService, let project = event.composeProject else { return }
        let key = ServiceKey(
            stack: ThrallStackID(
                engineKey: engineKey,
                projectName: project,
                workingDirectory: event.composeWorkingDirectory
                    .flatMap { $0.isEmpty ? nil : ThrallPathKey($0) }),
            service: service)
        var recorded = deaths[key] ?? []
        recorded.append(
            Death(
                containerID: event.containerID,
                exitCode: event.exitCode ?? 0,
                at: event.time))
        if recorded.count > limitPerService {
            recorded.removeFirst(recorded.count - limitPerService)
        }
        deaths[key] = recorded
    }

    func deaths(for key: ServiceKey) -> [Death] { deaths[key] ?? [] }

    /// Deaths within `window` of `now`, which is what the warm detector counts.
    func recentDeaths(for key: ServiceKey, since: Date) -> [Death] {
        (deaths[key] ?? []).filter { $0.at >= since }
    }

    /// Drops history for services that no longer exist, so a long session does
    /// not accumulate dead keys.
    mutating func prune(keeping live: Set<ServiceKey>) {
        deaths = deaths.filter { live.contains($0.key) }
    }
}
