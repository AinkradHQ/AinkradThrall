import Foundation

/// Tears a stack down **by label**, through the Engine API.
///
/// This is the orphaned-stack remedy, and it works precisely *because* it does
/// not need the compose file that `docker compose down` demands. On the
/// machine Thrall was designed against, 26 of 48 containers belonged to stacks
/// whose compose file had been deleted — unreachable by normal tooling, and
/// this is the only way to clean them up without hand-writing `docker rm`
/// commands.
///
/// **Volumes are never touched.** Not as an option, not behind a flag: the one
/// unrecoverable mistake this app can make is deleting a database volume, and
/// 93 of the 135 volumes on that machine were unreferenced — exactly the
/// population where a stray removal does damage. Volume deletion stays
/// human-in-UI on its own explicit path.
public struct ThrallOrphanTeardown: Sendable {
    public struct Outcome: Equatable, Sendable {
        public let stopped: [String]
        public let removed: [String]
        public let failures: [String]

        public var summary: String {
            var parts = ["removed \(removed.count)"]
            if !failures.isEmpty { parts.append("\(failures.count) failed") }
            return parts.joined(separator: ", ")
        }
    }

    /// Stops then removes every container in `stack`.
    ///
    /// Stop-then-remove, in that order and per container: removing a running
    /// container needs `force`, and `force` is a SIGKILL. A database that
    /// would have flushed on SIGTERM loses its last writes, which is a data
    /// loss this app has no business causing while tidying up.
    public static func run(stack: ThrallStack,
                           using client: ThrallEngineClient) async -> Outcome {
        var stopped: [String] = []
        var removed: [String] = []
        var failures: [String] = []

        for container in stack.services.flatMap(\.containers) {
            do {
                if container.state.isLive {
                    try await client.stop(containerID: container.id)
                    stopped.append(container.id)
                }
                try await client.remove(containerID: container.id)
                removed.append(container.id)
            } catch {
                // One container failing must not abandon the rest — a
                // half-torn-down stack is worse than either outcome.
                failures.append("\(container.name): \(error)")
            }
        }
        return Outcome(stopped: stopped, removed: removed, failures: failures)
    }
}

extension ThrallEngineClient {
    /// Removes a stopped container.
    ///
    /// **No `force`, and no `v`.** `force` SIGKILLs a running container, and
    /// `v` removes its anonymous volumes — which is the unrecoverable
    /// mistake. The caller stops the container first; a container that is
    /// still running here is a bug, and failing is the right answer to it.
    public func remove(containerID: String) async throws {
        try await deleteContainer(id: try Self.identifier(containerID))
    }

    private func deleteContainer(id: String) async throws {
        let prefix = try await version().pathPrefix
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(method: "DELETE",
                              target: Self.target(prefix + "/containers/\(id)",
                                                  query: [("v", "0"), ("force", "0")])),
            over: makeStream(),
            timeout: requestTimeout)
        // 404 means it is already gone, which is the outcome the caller wanted.
        guard response.head.statusCode == 204 || response.head.statusCode == 404 else {
            let message = (try? JSONDecoder().decode(ThrallEngineMessageDTO.self,
                                                     from: response.body))?.message
            throw ThrallEngineError.http(status: response.head.statusCode,
                                         message: message ?? response.head.reasonPhrase)
        }
    }
}
