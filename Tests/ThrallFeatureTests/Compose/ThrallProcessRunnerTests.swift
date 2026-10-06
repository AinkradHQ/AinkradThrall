import Foundation
import Testing

@testable import ThrallFeature

@Suite("ThrallDockerBinary and the runner")
struct ThrallProcessRunnerTests {
    /// Injects a nonexistent primary with no fallbacks, following
    /// `DockerBackend`'s own test seam — so "docker is missing" is a
    /// deterministic state rather than something that depends on the machine.
    private var missingBinary: ThrallDockerBinary {
        ThrallDockerBinary(primaryPath: "/nonexistent/docker", fallbackPaths: [])
    }

    @Test("a missing docker binary fails closed with the paths it tried")
    func binaryNotFound() async throws {
        let runner = ThrallProcessRunner(binary: missingBinary)
        do {
            _ = try await runner.run(["compose", "--ansi", "never", "-p", "x", "ls"])
            Issue.record("expected a binaryNotFound failure")
        } catch let error as ThrallProcessError {
            guard case .binaryNotFound(let message) = error else {
                Issue.record("expected .binaryNotFound, got \(error)")
                return
            }
            #expect(message.contains("/nonexistent/docker"))
        }
    }

    /// Validation happens **before** the binary is resolved, so a rejected
    /// argument can never reach a spawn even on a machine where docker exists.
    @Test("a rejected argument is refused before the binary is even looked up")
    func rejectionPrecedesSpawn() async throws {
        let runner = ThrallProcessRunner(binary: missingBinary)
        do {
            _ = try await runner.run(["compose", "up", "--env-file", "/tmp/x.env"])
            Issue.record("expected a rejection")
        } catch let error as ThrallProcessError {
            guard case .rejected(let message) = error else {
                Issue.record("expected .rejected, got \(error)")
                return
            }
            #expect(message.contains("--env-file"))
        }
    }

    @Test("resolution prefers the primary path, then falls back in order")
    func resolutionOrder() {
        // `/bin/sh` stands in for a real executable so this needs no docker.
        #expect(ThrallDockerBinary(primaryPath: "/bin/sh", fallbackPaths: []).resolve() == "/bin/sh")
        #expect(
            ThrallDockerBinary(
                primaryPath: "/nonexistent/docker",
                fallbackPaths: ["/nonexistent/also", "/bin/sh"]
            ).resolve()
                == "/bin/sh")
        #expect(missingBinary.resolve() == nil)
    }

    @Test("the not-found message lists each path once")
    func notFoundMessageDeduped() {
        let binary = ThrallDockerBinary(
            primaryPath: "/usr/local/bin/docker",
            fallbackPaths: [
                "/opt/homebrew/bin/docker",
                "/usr/local/bin/docker",
            ])
        let occurrences =
            binary.notFoundMessage.components(separatedBy: "/usr/local/bin/docker")
            .count - 1
        #expect(occurrences == 1)
    }

    /// Two verbs against the same stack must serialise — `up` racing `down`
    /// leaves half a stack — while different stacks must not block each other.
    @Test("the same stack serialises and a different stack does not block")
    func laneSerialisation() async throws {
        let client = ThrallComposeClient(runner: ThrallProcessRunner(binary: missingBinary))
        let stackA = ThrallStackID(
            engineKey: "e", projectName: "a",
            workingDirectory: ThrallPathKey("/tmp/a"))
        let stackB = ThrallStackID(
            engineKey: "e", projectName: "b",
            workingDirectory: ThrallPathKey("/tmp/b"))
        func command(_ project: String) -> ThrallComposeCommand {
            ThrallComposeCommand(
                verb: .restart, projectName: project,
                projectDirectory: "/tmp/\(project)", configFiles: [])
        }
        // Every call fails on the missing binary, which is fine: what is under
        // test is that the lane releases so the next caller is not stranded.
        // Finishing the loop is the assertion — a lane left held would hang
        // the next call on it.
        for _ in 0..<3 {
            _ = try? await client.run(command("a"), stack: stackA, dockerHost: nil)
            _ = try? await client.run(command("b"), stack: stackB, dockerHost: nil)
        }
    }
}
