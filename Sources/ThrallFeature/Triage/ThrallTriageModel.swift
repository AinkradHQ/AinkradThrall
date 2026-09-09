import Foundation

/// Assembles the triage surface: detect, read the evidence, group, order.
///
/// A separate `@MainActor` type rather than more surface on `ThrallViewModel`,
/// because the log reads it does are the one expensive thing in the app and
/// keeping them behind their own model makes the budget explicit.
@MainActor
public final class ThrallTriageModel: ObservableObject {
    @Published public private(set) var incidents: [ThrallIncident] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastScan: Date?
    /// True until the first scan completes. The **first-scan suppression** gate
    /// reads this: the opening reconcile seeds a baseline and emits nothing,
    /// or opening Thrall today would fire 15 urgent notifications at once.
    @Published public private(set) var hasBaseline = false

    private var history = ThrallEventHistory()
    /// Log tails already read, keyed by container id, so a rescan does not
    /// re-read a log that has not changed.
    private var logCache: [String: String] = [:]
    private var inspectCache: [String: ThrallContainerInspectDTO] = [:]

    public init() {}

    /// Records an event into history. Called by the stream supervisor.
    public func record(_ event: ThrallEvent, engineKey: String) {
        history.record(event, engineKey: engineKey)
    }

    /// Scans a world for incidents.
    ///
    /// `readLog` and `inspect` are injected so this whole assembly is testable
    /// without a daemon — and so the caller decides how much log reading it
    /// can afford.
    public func scan(world: ThrallWorld,
                     now: Date = Date(),
                     inspect: (String) async throws -> ThrallContainerInspectDTO,
                     readLog: (String) async throws -> String) async {
        isScanning = true
        defer {
            isScanning = false
            lastScan = now
            hasBaseline = true
        }

        // Only services with something wrong are candidates — inspecting all
        // 48 containers on every scan would put `inspect` on a hot path for no
        // reason.
        var candidates: [ThrallCrashLoopDetector.Candidate] = []
        for stack in world.stacks {
            for service in stack.services {
                let suspect = service.containers.filter { container in
                    switch container.state {
                    case .restarting, .exited, .dead: return true
                    default: return false
                    }
                }
                guard !suspect.isEmpty else { continue }
                var counts: [String: Int] = [:]
                var policies: [String: Bool] = [:]
                var finished: [String: Date] = [:]
                for container in suspect {
                    guard let detail = await inspected(container.id, using: inspect) else {
                        continue
                    }
                    counts[container.id] = detail.restartCount
                    policies[container.id] = detail.restartPolicy.canRestart
                    if let at = detail.state.finishedAt { finished[container.id] = at }
                }
                candidates.append(ThrallCrashLoopDetector.Candidate(
                    stack: stack.id, service: service.name, containers: suspect,
                    restartCounts: counts, restartPolicies: policies, finishedAt: finished))
            }
        }

        let loops = ThrallCrashLoopDetector.detectAll(candidates: candidates,
                                                       history: history, now: now)
        var inputs: [ThrallIncidentGrouper.Input] = []
        for loop in loops {
            let container = loop.containerIDs.first
                ?? world.stack(loop.stack)?.services
                    .first { $0.name == loop.service }?.containers.first?.id
            var tail: String?
            if let container { tail = await logTail(container, using: readLog) }
            let image = world.stack(loop.stack)?.services
                .first { $0.name == loop.service }?.containers.first?.image
            inputs.append(ThrallIncidentGrouper.Input(
                loop: loop,
                logTail: tail,
                imageDigest: image,
                firstSeen: history.deaths(for: .init(stack: loop.stack, service: loop.service))
                    .first?.at ?? now,
                lastSeen: history.deaths(for: .init(stack: loop.stack, service: loop.service))
                    .last?.at ?? now))
        }
        incidents = ThrallIncidentGrouper.group(inputs, world: world)
    }

    /// Prunes caches for containers that no longer exist. Without this a long
    /// session accumulates a log tail per container ever seen, and compose
    /// mints a new id on every recreate.
    public func prune(world: ThrallWorld) {
        let live = Set(world.stacks.flatMap { $0.services.flatMap { $0.containers.map(\.id) } })
        logCache = logCache.filter { live.contains($0.key) }
        inspectCache = inspectCache.filter { live.contains($0.key) }
        history.prune(keeping: Set(world.stacks.flatMap { stack in
            stack.services.map { ThrallEventHistory.ServiceKey(stack: stack.id,
                                                                service: $0.name) }
        }))
    }

    private func inspected(_ id: String,
                           using inspect: (String) async throws -> ThrallContainerInspectDTO)
        async -> ThrallContainerInspectDTO? {
        if let cached = inspectCache[id] { return cached }
        guard let detail = try? await inspect(id) else { return nil }
        inspectCache[id] = detail
        return detail
    }

    private func logTail(_ id: String,
                         using readLog: (String) async throws -> String) async -> String? {
        if let cached = logCache[id] { return cached }
        guard let tail = try? await readLog(id) else { return nil }
        logCache[id] = tail
        return tail
    }
}
