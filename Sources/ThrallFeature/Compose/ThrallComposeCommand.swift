import Foundation

/// Builds the argument vector for one compose verb.
///
/// Pure, so every vector Thrall can produce is testable — and every one of
/// them then goes through `ThrallComposeArgumentGuard` at the spawn point
/// anyway. Two checks of the same thing is the point: the builder is where
/// correctness lives, the guard is where it is *enforced* regardless of what
/// the builder does.
public struct ThrallComposeCommand: Equatable, Sendable {
    public enum Verb: String, Equatable, Sendable, CaseIterable {
        case up, down, start, stop, restart, pull, config, ps
    }

    public let verb: Verb
    public let projectName: String
    public let projectDirectory: String
    public let configFiles: [String]
    /// Empty means the whole stack.
    public let services: [String]

    public init(verb: Verb, projectName: String, projectDirectory: String,
                configFiles: [String], services: [String] = []) {
        self.verb = verb
        self.projectName = projectName
        self.projectDirectory = projectDirectory
        self.configFiles = configFiles
        self.services = services
    }

    /// The full argv tail, starting at `compose`.
    ///
    /// **`--context` is never here, in any form.** The engine is chosen by
    /// setting `DOCKER_HOST` from the endpoint Thrall already reads. A context
    /// name is a second lookup that can disagree with the transport, and the
    /// failure is bringing a stack up on one daemon while the UI shows another.
    public func arguments() throws -> [String] {
        guard ThrallComposeArgumentGuard.isValidIdentifier(projectName) else {
            throw ThrallComposeArgumentGuard.Rejection.identifier(projectName)
        }
        for service in services where !ThrallComposeArgumentGuard.isValidIdentifier(service) {
            throw ThrallComposeArgumentGuard.Rejection.identifier(service)
        }

        var arguments = ["compose", "--ansi", "never",
                         "--project-name", projectName,
                         "--project-directory", projectDirectory]
        // Order matters to compose: later files override earlier ones, and the
        // label lists them base-first.
        for file in configFiles {
            arguments += ["-f", file]
        }
        arguments.append(verb.rawValue)
        arguments += verbOptions
        if !services.isEmpty {
            // Terminate options before the service names so a service that
            // looks like a flag is data. The identifier check above already
            // refused it; this is the second lock on the same door.
            arguments.append("--")
            arguments += services
        }
        return arguments
    }

    private var verbOptions: [String] {
        switch verb {
        case .up:
            // `--remove-orphans` matters here specifically: this machine has 26
            // containers whose compose file moved, which is exactly how an
            // orphan is created.
            return ["-d", "--remove-orphans"]
        case .config, .ps:
            return ["--format", "json"]
        case .down, .start, .stop, .restart, .pull:
            // **No `-v` / `--volumes`, ever, from this builder.** Deleting a
            // volume is the one unrecoverable mistake this app can make, and
            // 93 of the 135 volumes here are unreferenced — precisely the
            // population where a stray flag does damage. Volume removal stays
            // human-in-UI, on its own explicit path.
            return []
        }
    }

    /// Whether this verb can run at all for the stack it targets.
    ///
    /// `up`, `pull` and `config` read the compose file, so an orphaned stack —
    /// whose files are gone — cannot use them. `docker compose down` needs the
    /// file too, which is why orphan teardown goes by **label** through the
    /// Engine API instead (M2).
    public var requiresConfigFiles: Bool {
        switch verb {
        case .up, .pull, .config, .down, .ps: return true
        case .start, .stop, .restart: return false
        }
    }
}
