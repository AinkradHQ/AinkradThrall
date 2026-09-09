import Foundation
import Testing
@testable import ThrallFeature

/// Task F's acceptance criterion, run against the real engine.
///
/// **On a throwaway project, never on a stack that is already running.** The
/// plan named the `compose` stack, but both `compose` stacks on this machine
/// turned out to be orphaned — their config files are gone, so no compose verb
/// can touch them at all. The only other candidate was `optimus`, which is the
/// user's live development environment. So this creates its own two-service
/// project in a temporary directory, drives it through Thrall's own code path,
/// and tears it down in a `defer` whether the test passes or not.
///
/// Uses `alpine:latest`, which is already local (14.6 MB), so nothing is
/// pulled and the test does not depend on a registry.
@Suite("Stack lifecycle, live", .serialized)
struct ThrallLifecycleLiveTests {
    private static let projectName = "thrall-lifecycle-check"

    private static var canRun: Bool {
        LiveEngine.socketPath != nil && ThrallDockerBinary().resolve() != nil
    }

    private func makeProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thrall-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Two services, so the test covers a stack rather than a container, and
        // `sleep` so they stay up long enough to be observed.
        let compose = """
            services:
              first:
                image: alpine:latest
                command: ["sleep", "300"]
              second:
                image: alpine:latest
                command: ["sleep", "300"]
            """
        try Data(compose.utf8).write(to: root.appendingPathComponent("docker-compose.yml"))
        return root
    }

    @Test("up then down reflects in the engine, through Thrall's own path",
          .enabled(if: canRun))
    func upThenDown() async throws {
        let root = try makeProject()
        let configFile = root.appendingPathComponent("docker-compose.yml").path
        let socket = try #require(LiveEngine.socketPath)
        let engine = try ThrallEngineClient(endpoint: .unixSocket(path: socket))
        let compose = ThrallComposeClient(runner: ThrallProcessRunner())
        let stackID = ThrallStackID(engineKey: "unix:\(socket)",
                                    projectName: Self.projectName,
                                    workingDirectory: ThrallPathKey(root.path))

        func command(_ verb: ThrallComposeCommand.Verb) -> ThrallComposeCommand {
            ThrallComposeCommand(verb: verb,
                                 projectName: Self.projectName,
                                 projectDirectory: root.path,
                                 configFiles: [configFile])
        }
        func reconciled() async throws -> ThrallStack? {
            let containers = try await engine.containers()
            return ThrallReconciler.reconcile(engineKey: "unix:\(socket)",
                                              containers: containers,
                                              probe: .filesystem)
                .stacks.first { $0.displayName == Self.projectName }
        }

        // Torn down whatever happens, so a failure cannot leave containers on
        // the user's engine. `defer` cannot await, so the teardown is an
        // explicit catch-and-rethrow instead.
        func teardown() async {
            _ = try? await compose.run(command(.down), stack: stackID,
                                       dockerHost: "unix://\(socket)")
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await body()
        } catch {
            await teardown()
            throw error
        }
        await teardown()

        func body() async throws {
        let up = try await compose.run(command(.up), stack: stackID,
                                       dockerHost: "unix://\(socket)")
        #expect(up.succeeded, Comment(rawValue: up.standardError))

        // The AC's "reflects within 1 s": one reconcile immediately after the
        // verb returns, with no sleep. `up -d` does not return until the
        // containers are created, so a poll interval is not needed to see them.
        let running = try #require(try await reconciled())
        #expect(running.services.map(\.name).sorted() == ["first", "second"])
        #expect(running.breakdown.running == 2)
        #expect(!running.isConfigMissing, "the compose file is right there on disk")
        #expect(running.health == .allRunning)

        let down = try await compose.run(command(.down), stack: stackID,
                                         dockerHost: "unix://\(socket)")
        #expect(down.succeeded, Comment(rawValue: down.standardError))
        let after = try await reconciled()
        #expect(after == nil, "down removes the containers, so the stack goes")
        }
    }

    /// The engine-level path, which is the **only** one an orphaned stack has:
    /// `docker compose` needs the file the stack was started from, and
    /// `aai1058`'s files are gone.
    @Test("engine-level stop and start work without any compose file",
          .enabled(if: canRun))
    func engineVerbsNeedNoConfig() async throws {
        let root = try makeProject()
        let configFile = root.appendingPathComponent("docker-compose.yml").path
        let socket = try #require(LiveEngine.socketPath)
        let engine = try ThrallEngineClient(endpoint: .unixSocket(path: socket))
        let compose = ThrallComposeClient(runner: ThrallProcessRunner())
        let stackID = ThrallStackID(engineKey: "unix:\(socket)",
                                    projectName: Self.projectName,
                                    workingDirectory: ThrallPathKey(root.path))
        func command(_ verb: ThrallComposeCommand.Verb) -> ThrallComposeCommand {
            ThrallComposeCommand(verb: verb, projectName: Self.projectName,
                                 projectDirectory: root.path, configFiles: [configFile])
        }
        func teardown() async {
            _ = try? await compose.run(command(.down), stack: stackID,
                                       dockerHost: "unix://\(socket)")
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await body()
        } catch {
            await teardown()
            throw error
        }
        await teardown()

        func body() async throws {
        _ = try await compose.run(command(.up), stack: stackID, dockerHost: "unix://\(socket)")

        let containers = try await engine.containers()
        let mine = containers.filter {
            $0.labels["com.docker.compose.project"] == Self.projectName
        }
        #expect(mine.count == 2)
        let target = try #require(mine.first)

        // Now delete the compose file: the stack becomes orphaned, exactly like
        // `aai1058`.
        try FileManager.default.removeItem(atPath: configFile)
        let orphaned = try #require(
            ThrallReconciler.reconcile(engineKey: "unix:\(socket)",
                                       containers: try await engine.containers(),
                                       probe: .filesystem)
                .stacks.first { $0.displayName == Self.projectName })
        #expect(orphaned.isConfigMissing, "the premise: no compose file, containers still running")

        // And the engine verbs still work on it.
        try await engine.stop(containerID: target.id)
        let stopped = try await engine.inspect(containerID: target.id)
        #expect(!stopped.state.running)
        #expect(stopped.state.finishedAt != nil, "a stopped container has a real FinishedAt")

        try await engine.start(containerID: target.id)
        #expect(try await engine.inspect(containerID: target.id).state.running)

        // Put the file back so the `defer` can tear the stack down with compose.
        try Data("""
            services:
              first:
                image: alpine:latest
                command: ["sleep", "300"]
              second:
                image: alpine:latest
                command: ["sleep", "300"]
            """.utf8).write(to: URL(fileURLWithPath: configFile))
        }
    }
}
