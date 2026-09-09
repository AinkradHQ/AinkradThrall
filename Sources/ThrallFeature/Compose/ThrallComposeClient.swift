import Foundation

/// Runs compose verbs, one at a time **per stack**.
///
/// **Per-stack serial lanes, not one global serial queue.** This is a
/// deliberate divergence from `GitRepositoryClient`, which serialises
/// everything through one actor. A `pull` on `optimus` takes minutes; behind a
/// global lane it would block a `stop` on `althaqeel` for all of it, and the
/// UI would look frozen while nothing was wrong. Two verbs against the *same*
/// stack must still serialise — compose is not safe to run concurrently
/// against one project, and `up` racing `down` leaves half a stack.
public actor ThrallComposeClient {
    private let runner: ThrallProcessRunner
    /// Lane keys currently held.
    private var busy: Set<String> = []
    /// FIFO of callers waiting on each lane.
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(runner: ThrallProcessRunner) {
        self.runner = runner
    }

    /// Runs `command` against `stack`, serialised with anything else on that
    /// stack's lane.
    public func run(_ command: ThrallComposeCommand,
                    stack: ThrallStackID,
                    dockerHost: String?) async throws -> ThrallProcessResult {
        let arguments = try command.arguments()
        let lane = stack.description
        await acquire(lane)
        defer { release(lane) }

        var runner = self.runner
        if let dockerHost {
            // The engine is selected **here and only here**. See
            // `ThrallComposeCommand.arguments()`: `--context` is never passed,
            // because it is a second lookup that can disagree with the socket
            // Thrall is reading.
            runner.environment["DOCKER_HOST"] = dockerHost
        }
        return try await runner.run(arguments, workingDirectory: command.projectDirectory)
    }

    /// True while a verb is running against `stack` — drives the row's spinner
    /// without the view having to track it.
    public func isBusy(_ stack: ThrallStackID) -> Bool {
        busy.contains(stack.description)
    }

    // MARK: - Lanes

    private func acquire(_ lane: String) async {
        while busy.contains(lane) {
            await withCheckedContinuation { continuation in
                waiting[lane, default: []].append(continuation)
            }
        }
        busy.insert(lane)
    }

    private func release(_ lane: String) {
        busy.remove(lane)
        guard var queue = waiting[lane], !queue.isEmpty else {
            waiting[lane] = nil
            return
        }
        let next = queue.removeFirst()
        waiting[lane] = queue.isEmpty ? nil : queue
        next.resume()
    }
}
