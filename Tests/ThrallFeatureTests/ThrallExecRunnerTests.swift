import Foundation
import Testing
@testable import ThrallFeature

/// **argv only, never a shell string.** Everything Thrall knows about a
/// container comes from the engine or a compose file, so a value reaching the
/// exec path can contain anything; argv removes the question rather than
/// filtering it.
@Suite("ThrallExecRunner argument parsing")
struct ThrallExecRunnerTests {
    @Test("a plain command splits into argv")
    func plainCommand() throws {
        #expect(try ThrallExecRunner.parse(commandLine: "nc -z db 5432")
            == ["nc", "-z", "db", "5432"])
        #expect(try ThrallExecRunner.parse(commandLine: "env") == ["env"])
        #expect(try ThrallExecRunner.parse(commandLine: "  cat  /etc/hosts  ")
            == ["cat", "/etc/hosts"])
    }

    /// Quoting is what makes the metacharacter check usable. Scanning the
    /// whole line *before* parsing rejected `php -r "echo 1;"` — a perfectly
    /// good command — so the check has to know about quotes. Inside them every
    /// metacharacter is literal data and argv passes it through unchanged,
    /// which is correct.
    @Test("quotes group an argument, and make metacharacters literal")
    func quoting() throws {
        #expect(try ThrallExecRunner.parse(commandLine: #"php -r "echo 1;""#)
            == ["php", "-r", "echo 1;"])
        #expect(try ThrallExecRunner.parse(commandLine: "ls 'my dir'") == ["ls", "my dir"])
        #expect(try ThrallExecRunner.parse(commandLine: #"grep "a|b" f"#)
            == ["grep", "a|b", "f"])
        #expect(try ThrallExecRunner.parse(commandLine: #"echo "$HOME""#)
            == ["echo", "$HOME"])
    }

    /// **Refused with a reason, not silently passed through as a literal.** A
    /// user typing `cat x > y` expects a redirect; getting a file named `>`
    /// with no explanation is worse than being told no.
    @Test("shell metacharacters are refused, and the message explains why",
          arguments: ["cat x > y", "ps | grep php", "a && b", "a; b", "echo $(id)",
                      "echo `id`", "cat < f", "a || b", "echo $PATH"])
    func shellMetacharactersRefused(line: String) {
        do {
            _ = try ThrallExecRunner.parse(commandLine: line)
            Issue.record("\(line) should have been refused")
        } catch let error as ThrallExecError {
            guard case .invalidArgument(let message) = error else {
                Issue.record("expected .invalidArgument, got \(error)")
                return
            }
            #expect(message.contains("no shell"))
            // And it points at the thing that does have one.
            #expect(message.contains("Rune"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("an empty command is refused", arguments: ["", "   ", "\n"])
    func emptyRefused(line: String) {
        #expect(throws: ThrallExecError.emptyCommand) {
            try ThrallExecRunner.parse(commandLine: line)
        }
    }

    @Test("an unclosed quote is refused rather than guessed at")
    func unclosedQuote() {
        #expect(throws: ThrallExecError.self) {
            try ThrallExecRunner.parse(commandLine: #"php -r "echo 1"#)
        }
    }

    /// Far short of anything that could be a script — this exists for
    /// diagnostic one-liners.
    @Test("too many arguments is refused")
    func argumentCap() {
        let long = (0...40).map { "arg\($0)" }.joined(separator: " ")
        #expect(throws: ThrallExecError.self) {
            try ThrallExecRunner.parse(commandLine: long)
        }
        #expect(ThrallExecRunner.maximumArguments == 24)
    }

    /// A control character in an argument is either a paste accident or an
    /// attempt at something; neither should reach the daemon.
    @Test("control characters are refused")
    func controlCharacters() {
        #expect(throws: ThrallExecError.self) {
            try ThrallExecRunner.parse(commandLine: "echo a\u{0007}b")
        }
        #expect(throws: ThrallExecError.self) {
            try ThrallExecRunner.parse(commandLine: "echo a\u{007F}b")
        }
    }

    /// The commands this exists for — roughly 80% of crash-loop triage.
    @Test("the triage one-liners the feature exists for all parse", arguments: [
        "env", "cat /etc/hosts", "nc -z db 5432", "ls -la /var/log",
        "php artisan --version", "pg_isready -h pgsql", "printenv DATABASE_URL",
    ])
    func triageCommandsParse(line: String) throws {
        #expect(!(try ThrallExecRunner.parse(commandLine: line)).isEmpty)
    }
}

/// The live half. Gated on a socket and a running container.
@Suite("Exec against a live container", .serialized)
struct ThrallExecLiveTests {
    private static var canRun: Bool { LiveEngine.socketPath != nil }

    /// **The framing correction, verified end to end.**
    /// `/exec/{id}/start` answers `Content-Type:
    /// application/vnd.docker.raw-stream` while its body is multiplexed —
    /// `01 00 00 00 00 00 01 b3` on the wire. Task B's "framing comes from the
    /// Content-Type" rule holds for `/containers/{id}/logs` but **not** here,
    /// so the runner trusts the `Tty: false` it sent itself. If that were
    /// wrong, this test would return frame headers as text.
    @Test("a live exec returns demuxed output and an exit code",
          .enabled(if: canRun))
    func liveExec() async throws {
        let path = try #require(LiveEngine.socketPath)
        let client = try ThrallEngineClient(endpoint: .unixSocket(path: path))
        let running = try await client.containers(all: false)
        guard let target = running.first else {
            // Nothing running is a legitimate machine state, not a failure.
            return
        }
        let runner = ThrallExecRunner(client: client)
        let result = try await runner.run(containerID: target.id,
                                          command: try ThrallExecRunner.parse(commandLine: "env"))
        #expect(result.exitCode == 0)
        #expect(!result.stdout.isEmpty)
        #expect(result.stdout.contains("PATH="))
        // The proof it was demuxed: a frame header byte would have landed in
        // the text.
        #expect(!result.stdout.unicodeScalars.contains { $0.value == 1 })
        #expect(!result.truncated)
    }

    @Test("a failing command reports its nonzero exit code", .enabled(if: canRun))
    func liveExecFailure() async throws {
        let path = try #require(LiveEngine.socketPath)
        let client = try ThrallEngineClient(endpoint: .unixSocket(path: path))
        guard let target = try await client.containers(all: false).first else { return }
        let runner = ThrallExecRunner(client: client)
        let result = try await runner.run(
            containerID: target.id,
            command: try ThrallExecRunner.parse(commandLine: "cat /nonexistent-thrall-probe"))
        #expect(result.exitCode != 0)
        #expect(!result.succeeded)
        // stderr is kept separate, which is what the demux is for.
        #expect(!result.stderr.isEmpty)
    }
}
