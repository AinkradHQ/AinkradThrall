import Foundation
import Testing
@testable import ThrallFeature

/// Resolution has to agree with the user's own `docker ps`, or neither Thrall
/// nor the CLI is trustworthy. These build a real Docker config directory in a
/// temporary folder rather than mocking a filesystem — the parsing is the part
/// under test, and it should be reading real bytes off a real disk.
@Suite("ThrallContextResolver")
struct ThrallContextResolverTests {
    struct StoredContext {
        let name: String
        let host: String
        var description: String? = nil
        var includeDockerEndpoint = true
    }

    /// Writes a config directory. Meta directories are named after the context
    /// rather than `sha256(name)` — the real store uses the hash (verified
    /// against every context on this machine), but the resolver scans, so the
    /// name is enough here and keeps the fixture readable.
    private func makeStore(currentContext: String?, contexts: [StoredContext]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thrall-ctx-\(UUID().uuidString)")
        let meta = root.appendingPathComponent("contexts/meta")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)

        var config: [String: Any] = ["auths": [:]]
        if let currentContext { config["currentContext"] = currentContext }
        try JSONSerialization.data(withJSONObject: config)
            .write(to: root.appendingPathComponent("config.json"))

        for context in contexts {
            let directory = meta.appendingPathComponent(context.name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var payload: [String: Any] = ["Name": context.name]
            if let description = context.description {
                payload["Metadata"] = ["Description": description]
            }
            if context.includeDockerEndpoint {
                payload["Endpoints"] = ["docker": ["Host": context.host, "SkipTLSVerify": false]]
            } else {
                payload["Endpoints"] = ["kubernetes": ["Host": context.host]]
            }
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: directory.appendingPathComponent("meta.json"))
        }
        return root
    }

    private func orbstackStore() throws -> URL {
        try makeStore(currentContext: "orbstack", contexts: [
            StoredContext(name: "orbstack",
                          host: "unix:///Users/me/.orbstack/run/docker.sock",
                          description: "OrbStack"),
            StoredContext(name: "desktop-linux",
                          host: "unix:///Users/me/.docker/run/docker.sock",
                          description: "Docker Desktop"),
        ])
    }

    @Test("currentContext selects the engine, and default is always listed")
    func currentContextSelects() throws {
        let root = try orbstackStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ThrallContextResolver(configDirectory: root, environment: [:]).resolve()

        #expect(resolution.activeName == "orbstack")
        #expect(resolution.active?.endpoint
            == .unixSocket(path: "/Users/me/.orbstack/run/docker.sock"))
        #expect(resolution.active?.source == .contextStore)
        #expect(resolution.active?.description == "OrbStack")
        // The three contexts this machine has: the two stored plus the
        // implicit default, which is never in the store.
        #expect(resolution.contexts.map(\.name) == ["default", "desktop-linux", "orbstack"])
        #expect(resolution.contexts.first?.source == .platformDefault)
    }

    /// The CLI ignores the context store entirely when `DOCKER_HOST` is set, so
    /// `currentContext` becomes decoration. Thrall says so instead of showing a
    /// context it is not using.
    @Test("DOCKER_HOST overrides the current context, and says that it did")
    func environmentOverrides() throws {
        let root = try orbstackStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ThrallContextResolver(
            configDirectory: root,
            environment: ["DOCKER_HOST": "unix:///tmp/other.sock"]).resolve()

        #expect(resolution.activeName == "default")
        #expect(resolution.active?.endpoint == .unixSocket(path: "/tmp/other.sock"))
        #expect(resolution.active?.source == .environment)
        #expect(resolution.notes.contains { $0.contains("DOCKER_HOST") && $0.contains("overrides") })
        // orbstack is still listed — it exists, it just is not current.
        #expect(resolution.contexts.contains { $0.name == "orbstack" })
    }

    @Test("DOCKER_CONTEXT overrides currentContext but not DOCKER_HOST")
    func dockerContextOverrides() throws {
        let root = try orbstackStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ThrallContextResolver(configDirectory: root,
                                             environment: ["DOCKER_CONTEXT": "desktop-linux"])
        #expect(resolver.resolve().activeName == "desktop-linux")

        let both = ThrallContextResolver(
            configDirectory: root,
            environment: ["DOCKER_CONTEXT": "desktop-linux",
                          "DOCKER_HOST": "unix:///tmp/other.sock"])
        #expect(both.resolve().activeName == "default")
    }

    /// **The important negative.** Falling back to `default` here would drive a
    /// different daemon than the user believes — which with three contexts
    /// configured is a real way to stop the wrong database.
    @Test("a current context that is missing resolves to nothing, never to default")
    func missingContextDoesNotFallBack() throws {
        let root = try makeStore(currentContext: "colima", contexts: [
            StoredContext(name: "orbstack", host: "unix:///tmp/orb.sock"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ThrallContextResolver(configDirectory: root, environment: [:]).resolve()

        #expect(resolution.activeName == "colima")
        #expect(resolution.active == nil)
        #expect(resolution.notes.contains { $0.contains("colima") })
    }

    @Test("no currentContext at all means default")
    func noCurrentContext() throws {
        let root = try makeStore(currentContext: nil, contexts: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ThrallContextResolver(configDirectory: root,
                                               environment: [:],
                                               platformSocketPath: "/var/run/docker.sock").resolve()
        #expect(resolution.activeName == "default")
        #expect(resolution.active?.endpoint == .unixSocket(path: "/var/run/docker.sock"))
    }

    @Test("a context with no docker endpoint is skipped with a reason")
    func contextWithoutDockerEndpoint() throws {
        let root = try makeStore(currentContext: "orbstack", contexts: [
            StoredContext(name: "orbstack", host: "unix:///tmp/orb.sock"),
            StoredContext(name: "kube-only", host: "https://k8s.test",
                          includeDockerEndpoint: false),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ThrallContextResolver(configDirectory: root, environment: [:]).resolve()
        #expect(!resolution.contexts.contains { $0.name == "kube-only" })
        #expect(resolution.notes.contains { $0.contains("kube-only") })
    }

    @Test("a remote context is listed, refused, and explained")
    func remoteContextIsListedNotDropped() throws {
        let root = try makeStore(currentContext: "remote", contexts: [
            StoredContext(name: "remote", host: "tcp://10.0.0.4:2376"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ThrallContextResolver(configDirectory: root, environment: [:]).resolve()
        #expect(resolution.active?.isSupported == false)
        #expect(resolution.notes.contains { $0.contains("remote") })
    }

    @Test("a store entry cannot shadow the synthetic default")
    func storeCannotShadowDefault() throws {
        let root = try makeStore(currentContext: "default", contexts: [
            StoredContext(name: "default", host: "unix:///tmp/impostor.sock"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ThrallContextResolver(configDirectory: root,
                                               environment: [:],
                                               platformSocketPath: "/var/run/docker.sock").resolve()
        #expect(resolution.contexts.filter { $0.name == "default" }.count == 1)
        #expect(resolution.active?.endpoint == .unixSocket(path: "/var/run/docker.sock"))
    }

    @Test("a DOCKER_HOST that names nothing falls back to the store, and says so")
    func unparseableEnvironmentHost() throws {
        let root = try orbstackStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolution = ThrallContextResolver(configDirectory: root,
                                               environment: ["DOCKER_HOST": "not-a-host"]).resolve()
        #expect(resolution.activeName == "orbstack")
        #expect(resolution.notes.contains { $0.contains("not-a-host") })
    }

    @Test("a missing config directory resolves to default rather than throwing")
    func missingConfigDirectory() {
        let resolution = ThrallContextResolver(
            configDirectory: URL(fileURLWithPath: "/nonexistent/thrall-docker"),
            environment: [:]).resolve()
        #expect(resolution.activeName == "default")
        #expect(resolution.contexts.map(\.name) == ["default"])
    }

    // MARK: - Against the real store on this machine

    /// Reads `~/.docker` as it actually is. Gated on the directory existing so
    /// the suite still passes on a machine with no Docker CLI installed.
    @Test("the real context store on this machine resolves",
          .enabled(if: FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".docker/contexts/meta").path)))
    func realStore() throws {
        // The environment is passed empty on purpose: this asserts what the
        // store says, not what this test process happens to inherit.
        let resolution = ThrallContextResolver.system(environment: [:]).resolve()
        #expect(resolution.contexts.contains { $0.name == "default" })
        let active = try #require(resolution.active)
        #expect(active.isSupported, "the active context should be a unix socket")
        guard case .unixSocket(let path) = active.endpoint else { return }
        #expect(path.hasSuffix(".sock"))
    }
}
