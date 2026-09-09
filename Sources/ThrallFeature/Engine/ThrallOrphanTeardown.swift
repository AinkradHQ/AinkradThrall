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

extension ThrallEngineClient {
    /// Removes one image by **exact id**.
    ///
    /// No `force`: a force-remove untags an image other containers may still
    /// reference by tag, which breaks a stack that was working. If the engine
    /// refuses because something depends on it, that refusal is correct and is
    /// surfaced rather than overridden.
    public func removeImage(id: String) async throws {
        try await delete(path: "/images/\(try Self.imageReference(id))",
                         query: [("force", "0"), ("noprune", "0")],
                         accepting: [200, 404])
    }

    /// Removes one volume by **exact name**.
    ///
    /// The single most dangerous call in this app, and the reason it exists at
    /// all rather than a prune: the caller has already shown the user this
    /// exact name. `force=0`, so a volume that turns out to be in use is
    /// refused by the engine instead of destroyed.
    public func removeVolume(name: String) async throws {
        try await delete(path: "/volumes/\(try Self.identifier(name))",
                         query: [("force", "0")],
                         accepting: [204, 404])
    }

    public func removeNetwork(id: String) async throws {
        try await delete(path: "/networks/\(try Self.identifier(id))",
                         query: [],
                         accepting: [204, 404])
    }

    /// Deletes one build-cache record by id.
    ///
    /// The engine has no per-record delete — `/build/prune` is the only route,
    /// and it takes filters rather than ids. So Thrall passes the **exact ids**
    /// as an `id` filter, which keeps the "remove what was shown" contract
    /// even though the endpoint is named prune. It is never called with an
    /// empty filter, which is what a bare prune would be.
    public func pruneBuildCache(ids: [String]) async throws -> Int64 {
        guard !ids.isEmpty else { return 0 }
        let filters = ["id": ids]
        guard let data = try? JSONSerialization.data(withJSONObject: filters) else {
            throw ThrallEngineError.decoding(type: "build prune filters", detail: "unencodable")
        }
        let prefix = try await version().pathPrefix
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(method: "POST",
                              target: Self.target(prefix + "/build/prune",
                                                  query: [("filters",
                                                           String(decoding: data, as: UTF8.self))])),
            over: makeStream(),
            timeout: requestTimeout)
        guard response.head.isSuccess else {
            throw ThrallEngineError.http(status: response.head.statusCode,
                                         message: response.head.reasonPhrase)
        }
        struct Reply: Decodable {
            let spaceReclaimed: Int64?
            enum CodingKeys: String, CodingKey { case spaceReclaimed = "SpaceReclaimed" }
        }
        return (try? JSONDecoder().decode(Reply.self, from: response.body))?.spaceReclaimed ?? 0
    }

    private func delete(path: String, query: [(String, String)],
                        accepting: Set<Int>) async throws {
        let prefix = try await version().pathPrefix
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(method: "DELETE",
                              target: Self.target(prefix + path, query: query)),
            over: makeStream(),
            timeout: requestTimeout)
        guard accepting.contains(response.head.statusCode) else {
            let message = (try? JSONDecoder().decode(ThrallEngineMessageDTO.self,
                                                     from: response.body))?.message
            throw ThrallEngineError.http(status: response.head.statusCode,
                                         message: message ?? response.head.reasonPhrase)
        }
    }

    /// An image reference is not a plain identifier: `sha256:abc…` and
    /// `repo/name:tag` both need to survive, so `:` and `/` are allowed here
    /// where `identifier(_:)` refuses them. Everything that could change the
    /// path — `..`, `?`, whitespace, control characters — still cannot pass.
    static func imageReference(_ raw: String) throws -> String {
        let allowed = { (character: Character) -> Bool in
            character.isASCII && (character.isLetter || character.isNumber
                || "_.-:/@".contains(character))
        }
        guard !raw.isEmpty, raw.count <= 255, raw.allSatisfy(allowed),
              !raw.contains(".."), let first = raw.first,
              first.isLetter || first.isNumber else {
            throw ThrallEngineError.decoding(type: "image reference",
                                             detail: "\(raw.debugDescription) is not an image id")
        }
        // Percent-encoded because a tag's `:` and `/` are path-significant.
        var allowedSet = CharacterSet.alphanumerics
        allowedSet.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowedSet) ?? raw
    }
}
