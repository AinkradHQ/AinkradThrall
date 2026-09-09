import Foundation
import Testing
@testable import ThrallFeature

/// The guard is a security boundary, so these are the tests that matter most
/// in Task F. Every value that reaches it comes from a compose file or the
/// engine, not from a literal in our source.
@Suite("ThrallComposeArgumentGuard")
struct ThrallComposeArgumentGuardTests {
    private func vector(_ tail: [String]) -> [String] {
        ["compose", "--ansi", "never", "--project-name", "optimus",
         "--project-directory", "/Users/me/Projects/Optimus/Run",
         "-f", "/Users/me/Projects/Optimus/Run/docker-compose.yml"] + tail
    }

    @Test("the vectors Thrall actually builds are accepted",
          arguments: ThrallComposeCommand.Verb.allCases)
    func builtVectorsPass(verb: ThrallComposeCommand.Verb) throws {
        let command = ThrallComposeCommand(
            verb: verb,
            projectName: "optimus",
            projectDirectory: "/Users/me/Projects/Optimus/Run",
            configFiles: ["/Users/me/Projects/Optimus/Run/docker-compose.yml",
                          "/Users/me/Projects/Optimus/Run/docker-compose.dev.yml"],
            services: ["api", "pgsql"])
        #expect(ThrallComposeArgumentGuard.rejection(in: try command.arguments()) == nil)
    }

    /// **The AC case.** A service named `--rm` in a cloned compose file becomes
    /// a flag the moment it is interpolated into argv.
    @Test("a service named like a flag is refused", arguments: [
        "--rm", "-v", "--volumes", "--env-file", "-f", "--project-name=other",
    ])
    func flagNamedService(name: String) {
        // Refused at the builder…
        let command = ThrallComposeCommand(verb: .restart, projectName: "optimus",
                                           projectDirectory: "/tmp", configFiles: ["/tmp/c.yml"],
                                           services: [name])
        #expect(throws: ThrallComposeArgumentGuard.Rejection.self) { try command.arguments() }
        // …and independently at the guard, if a vector ever reaches it another
        // way. After a `--` terminator the dash check no longer fires, so the
        // identifier rule is what catches it.
        #expect(ThrallComposeArgumentGuard.rejection(in: vector(["restart", "--", name])) != nil)
    }

    /// Reads an arbitrary file into the child's environment **and** changes
    /// project-name resolution, so it can silently retarget a command at a
    /// different stack.
    @Test("--env-file is refused in both spellings")
    func envFileRefused() {
        for tail in [["up", "--env-file", "/tmp/evil.env"], ["up", "--env-file=/tmp/evil.env"]] {
            #expect(ThrallComposeArgumentGuard.rejection(in: vector(tail))
                == .forbidden("--env-file"))
        }
    }

    /// A context name is a *second* engine lookup that can disagree with the
    /// socket Thrall is reading — the failure is bringing a stack up on
    /// `desktop-linux` while the UI shows `orbstack`.
    @Test("every way of selecting a different engine is refused", arguments: [
        ["--context", "desktop-linux"], ["--context=desktop-linux"],
        ["-H", "tcp://10.0.0.4:2376"], ["--host", "tcp://10.0.0.4:2376"],
        ["--tls"], ["--tlsverify"], ["--tlscacert", "/tmp/ca.pem"],
    ])
    func engineSelectionRefused(option: [String]) {
        let rejection = ThrallComposeArgumentGuard.rejection(in: vector(["up"] + option))
        guard case .forbidden = rejection else {
            Issue.record("expected .forbidden, got \(String(describing: rejection))")
            return
        }
    }

    /// **`--format` accepts a Go template** — an expression language with
    /// function calls — so allowing the option while ignoring its value allows
    /// arbitrary evaluation.
    @Test("--format is pinned to json", arguments: [
        "{{.Name}}", "{{range .}}{{.}}{{end}}", "table", "yaml", "",
    ])
    func formatValuePinned(value: String) {
        #expect(ThrallComposeArgumentGuard.rejection(in: vector(["ps", "--format", value]))
            == .optionValue(option: "--format", value: value))
        #expect(ThrallComposeArgumentGuard.rejection(in: vector(["ps", "--format=\(value)"]))
            == .optionValue(option: "--format", value: value))
    }

    @Test("--ansi is pinned to never")
    func ansiValuePinned() {
        #expect(ThrallComposeArgumentGuard.rejection(in: ["compose", "--ansi", "always", "up"])
            == .optionValue(option: "--ansi", value: "always"))
    }

    @Test("an unknown subcommand is refused", arguments: [
        "exec", "run", "cp", "kill", "rm", "events", "logs", "version", "",
    ])
    func unknownSubcommand(name: String) {
        #expect(ThrallComposeArgumentGuard.rejection(in: vector([name]))
            == .subcommand(name))
    }

    @Test("an unknown option is refused", arguments: [
        "--volumes", "-v", "--rmi", "--force-recreate", "--build", "--scale",
    ])
    func unknownOption(option: String) {
        #expect(ThrallComposeArgumentGuard.rejection(in: vector(["up", option]) ) != nil)
    }

    @Test("a vector that is not a compose invocation at all is refused")
    func notCompose() {
        #expect(ThrallComposeArgumentGuard.rejection(in: ["run", "--rm", "alpine"]) != nil)
        #expect(ThrallComposeArgumentGuard.rejection(in: []) != nil)
    }

    @Test("a value option with a missing value is refused rather than eating the next option")
    func missingValue() {
        #expect(ThrallComposeArgumentGuard.rejection(in: ["compose", "-f"]) != nil)
        #expect(ThrallComposeArgumentGuard.rejection(in: ["compose", "-f", "--project-name", "x", "up"])
            == .missingValue("-f"))
    }

    @Test("a subcommand is required")
    func subcommandRequired() {
        #expect(ThrallComposeArgumentGuard.rejection(in: ["compose", "--ansi", "never"])
            == .subcommand(""))
    }

    @Test("compose identifiers follow compose's own rule", arguments: [
        ("optimus", true), ("aai1058", true), ("laravel.test", true), ("queue-bg", true),
        ("a_b", true), ("1x", true),
        ("--rm", false), ("-v", false), (".hidden", false), ("_leading", false),
        ("", false), ("a b", false), ("a/b", false), ("a;b", false), ("a$(id)", false),
        ("../etc", false), ("a\nb", false),
    ])
    func identifierRule(value: String, valid: Bool) {
        #expect(ThrallComposeArgumentGuard.isValidIdentifier(value) == valid)
    }

    /// Deleting a volume is the one unrecoverable mistake this app can make,
    /// and 93 of the 135 volumes here are unreferenced — exactly the
    /// population where a stray flag does damage.
    @Test("no built vector can ever carry a volume-removal flag",
          arguments: ThrallComposeCommand.Verb.allCases)
    func noVolumeRemoval(verb: ThrallComposeCommand.Verb) throws {
        let arguments = try ThrallComposeCommand(
            verb: verb, projectName: "optimus", projectDirectory: "/tmp",
            configFiles: ["/tmp/c.yml"]).arguments()
        for forbidden in ["-v", "--volumes", "--rmi", "--remove-volumes"] {
            #expect(!arguments.contains(forbidden))
        }
    }

    /// `--context` never appears, in any form, from any verb.
    @Test("no built vector selects an engine",
          arguments: ThrallComposeCommand.Verb.allCases)
    func noEngineSelection(verb: ThrallComposeCommand.Verb) throws {
        let arguments = try ThrallComposeCommand(
            verb: verb, projectName: "optimus", projectDirectory: "/tmp",
            configFiles: ["/tmp/c.yml"]).arguments()
        #expect(!arguments.contains { $0.hasPrefix("--context") || $0 == "-H"
            || $0.hasPrefix("--host") || $0.hasPrefix("--tls") })
    }
}

@Suite("ThrallComposeCommand")
struct ThrallComposeCommandTests {
    @Test("config files keep their order — later files override earlier ones")
    func fileOrderPreserved() throws {
        let arguments = try ThrallComposeCommand(
            verb: .up, projectName: "aai1058", projectDirectory: "/tmp/wt",
            configFiles: ["/tmp/wt/docker-compose.yml", "/tmp/wt/docker-compose.dev.yml"])
            .arguments()
        let files = zip(arguments, arguments.dropFirst())
            .filter { $0.0 == "-f" }.map(\.1)
        #expect(files == ["/tmp/wt/docker-compose.yml", "/tmp/wt/docker-compose.dev.yml"])
    }

    /// This machine has 26 containers whose compose file moved — which is
    /// exactly how an orphan is created, so `up` cleans them up.
    @Test("up detaches and removes orphans")
    func upOptions() throws {
        let arguments = try ThrallComposeCommand(verb: .up, projectName: "x",
                                                 projectDirectory: "/tmp",
                                                 configFiles: ["/tmp/c.yml"]).arguments()
        #expect(arguments.contains("-d"))
        #expect(arguments.contains("--remove-orphans"))
    }

    @Test("service names are placed after an option terminator")
    func servicesAfterTerminator() throws {
        let arguments = try ThrallComposeCommand(verb: .restart, projectName: "x",
                                                 projectDirectory: "/tmp",
                                                 configFiles: ["/tmp/c.yml"],
                                                 services: ["api"]).arguments()
        let terminator = try #require(arguments.firstIndex(of: "--"))
        #expect(arguments[(terminator + 1)...] == ["api"])
    }

    /// An orphaned stack cannot use these at all: every one needs the file the
    /// stack was started from.
    @Test("the verbs that read the compose file are marked as needing it")
    func requiresConfigFiles() {
        for verb in [ThrallComposeCommand.Verb.up, .down, .pull, .config, .ps] {
            #expect(ThrallComposeCommand(verb: verb, projectName: "x", projectDirectory: "/tmp",
                                         configFiles: []).requiresConfigFiles)
        }
        for verb in [ThrallComposeCommand.Verb.start, .stop, .restart] {
            #expect(!ThrallComposeCommand(verb: verb, projectName: "x", projectDirectory: "/tmp",
                                          configFiles: []).requiresConfigFiles)
        }
    }

    @Test("a project name that is not an identifier is refused")
    func invalidProjectName() {
        #expect(throws: ThrallComposeArgumentGuard.Rejection.identifier("--rm")) {
            try ThrallComposeCommand(verb: .up, projectName: "--rm", projectDirectory: "/tmp",
                                     configFiles: []).arguments()
        }
    }
}

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
        #expect(ThrallDockerBinary(primaryPath: "/nonexistent/docker",
                                   fallbackPaths: ["/nonexistent/also", "/bin/sh"]).resolve()
            == "/bin/sh")
        #expect(missingBinary.resolve() == nil)
    }

    @Test("the not-found message lists each path once")
    func notFoundMessageDeduped() {
        let binary = ThrallDockerBinary(primaryPath: "/usr/local/bin/docker",
                                        fallbackPaths: ["/opt/homebrew/bin/docker",
                                                        "/usr/local/bin/docker"])
        let occurrences = binary.notFoundMessage.components(separatedBy: "/usr/local/bin/docker")
            .count - 1
        #expect(occurrences == 1)
    }

    /// Two verbs against the same stack must serialise — `up` racing `down`
    /// leaves half a stack — while different stacks must not block each other.
    @Test("the same stack serialises and a different stack does not block")
    func laneSerialisation() async throws {
        let client = ThrallComposeClient(runner: ThrallProcessRunner(binary: missingBinary))
        let stackA = ThrallStackID(engineKey: "e", projectName: "a",
                                   workingDirectory: ThrallPathKey("/tmp/a"))
        let stackB = ThrallStackID(engineKey: "e", projectName: "b",
                                   workingDirectory: ThrallPathKey("/tmp/b"))
        func command(_ project: String) -> ThrallComposeCommand {
            ThrallComposeCommand(verb: .restart, projectName: project,
                                 projectDirectory: "/tmp/\(project)", configFiles: [])
        }
        // Every call fails on the missing binary, which is fine: what is under
        // test is that the lane releases so the next caller is not stranded.
        for _ in 0..<3 {
            _ = try? await client.run(command("a"), stack: stackA, dockerHost: nil)
            _ = try? await client.run(command("b"), stack: stackB, dockerHost: nil)
        }
        #expect(!(await client.isBusy(stackA)))
        #expect(!(await client.isBusy(stackB)))
    }
}
