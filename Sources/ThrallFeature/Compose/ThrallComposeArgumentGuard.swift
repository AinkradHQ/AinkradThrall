import Foundation

/// Refuses to hand `docker compose` anything this module did not author.
///
/// ## Why an allowlist, checked at the choke point
///
/// Following `GitArgumentGuard`, which earned both halves of that sentence. A
/// per-call-site `--` fixes the twenty call sites that exist and regresses on
/// the twenty-first, so the check lives inside `ThrallComposeClient`'s single
/// spawn path. And a denylist enumerates only the attacks you thought of.
///
/// ## What compose specifically requires beyond a subcommand allowlist
///
///  1. **Option *values* must be pinned, not just option names.** `--format`
///     accepts a Go template — an expression language with function calls — so
///     allowing `--format` while ignoring its value allows arbitrary
///     evaluation. Only `json` is permitted. `--ansi` likewise only `never`.
///  2. **`--env-file` is rejected outright.** It reads an arbitrary file into
///     the child's environment *and* changes project-name resolution, so it can
///     silently retarget a command at a different stack.
///  3. **`--context`, `-H`, `--host` and every `--tls*` are rejected.** The
///     engine is selected by setting `DOCKER_HOST` from the endpoint Thrall is
///     already reading. A context name is a *second* lookup that can disagree
///     with the transport — which brings a stack up on `desktop-linux` while
///     the UI shows `orbstack`.
///  4. **Identifiers are validated.** A service named `--rm` in a cloned
///     compose file becomes a flag the moment it is interpolated into argv.
///     Compose's own identifier rule is the allowlist.
public enum ThrallComposeArgumentGuard {
    /// The complete set of compose subcommands Thrall will run. `ls` is
    /// advisory only — it under-reports (2 of 5 projects here) and never
    /// decides anything.
    public static let allowedSubcommands: Set<String> = [
        "config", "up", "down", "start", "stop", "restart", "pull", "build", "ps", "ls",
    ]

    /// Bare options with no value.
    public static let allowedFlags: Set<String> = [
        "-d", "--detach", "--no-deps", "--remove-orphans", "--wait", "--quiet-pull",
        "--all", "--services", "--no-color", "--dry-run", "--timestamps",
        "--", "--end-of-options",
    ]

    /// Options that take a value, mapped to the values that are permitted.
    /// An empty set means "any value, validated separately as a path or
    /// identifier".
    public static let allowedValueOptions: [String: Set<String>] = [
        // Pinned: `--format` otherwise accepts a Go template.
        "--format": ["json"],
        "--ansi": ["never"],
        // Free-valued, but every value Thrall passes is a path or an
        // identifier it has already validated.
        "-f": [], "--file": [],
        "-p": [], "--project-name": [],
        "--project-directory": [],
        "--timeout": [],
    ]

    /// Rejected however they are spelled. Each one either reads a file into the
    /// environment or selects a *different engine* than the one on screen.
    public static let forbiddenOptions: Set<String> = [
        "--env-file", "--context", "-c", "-H", "--host",
        "--tls", "--tlsverify", "--tlscacert", "--tlscert", "--tlskey",
        "--parallel", "--profile", "--compatibility",
    ]

    public enum Rejection: Error, Equatable, Sendable {
        case subcommand(String)
        case option(String)
        case optionValue(option: String, value: String)
        case forbidden(String)
        case identifier(String)
        case missingValue(String)

        public var message: String {
            switch self {
            case .subcommand(let name):
                return "compose subcommand \(name.debugDescription) is not allowed"
            case .option(let name):
                return "option \(name.debugDescription) is not one Thrall passes"
            case .optionValue(let option, let value):
                return "option \(option) may not take the value \(value.debugDescription)"
            case .forbidden(let name):
                return "option \(name.debugDescription) is refused: it selects a different "
                    + "engine or reads an arbitrary file"
            case .identifier(let value):
                return "\(value.debugDescription) is not a valid compose identifier"
            case .missingValue(let name):
                return "option \(name) was passed with no value"
            }
        }
    }

    /// Compose's identifier rule. Anchored at both ends, which is the point: a
    /// value that merely *contains* something valid is still rejected.
    public static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        guard let first = value.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "_" || character == "." || character == "-")
        }
    }

    /// Checks a full argument vector, `compose` first.
    ///
    /// Returns nil when every argument is one this module authored.
    public static func rejection(in arguments: [String]) -> Rejection? {
        guard let first = arguments.first, first == "compose" else {
            return .subcommand(arguments.first ?? "")
        }
        var index = 1
        var subcommand: String?
        var optionsTerminated = false

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            if argument == "--" || argument == "--end-of-options" {
                optionsTerminated = true
                continue
            }
            if !optionsTerminated, argument.hasPrefix("-") {
                // Checked before the allowlist, so a forbidden option cannot be
                // rescued by also appearing in `allowedFlags`.
                if forbiddenOptions.contains(argument) { return .forbidden(argument) }
                // `--opt=value` and `--opt value` are the same thing to
                // compose, so both spellings go through one check.
                if let equals = argument.firstIndex(of: "=") {
                    let name = String(argument[argument.startIndex..<equals])
                    let value = String(argument[argument.index(after: equals)...])
                    if forbiddenOptions.contains(name) { return .forbidden(name) }
                    guard let permitted = allowedValueOptions[name] else { return .option(name) }
                    if !permitted.isEmpty, !permitted.contains(value) {
                        return .optionValue(option: name, value: value)
                    }
                    continue
                }
                if allowedFlags.contains(argument) { continue }
                guard let permitted = allowedValueOptions[argument] else {
                    return .option(argument)
                }
                guard index < arguments.count else { return .missingValue(argument) }
                let value = arguments[index]
                index += 1
                if !permitted.isEmpty, !permitted.contains(value) {
                    return .optionValue(option: argument, value: value)
                }
                // A value that starts with a dash means the real value went
                // missing and the next option got eaten.
                if permitted.isEmpty, value.hasPrefix("-") { return .missingValue(argument) }
                continue
            }
            if subcommand == nil {
                guard allowedSubcommands.contains(argument) else { return .subcommand(argument) }
                subcommand = argument
                continue
            }
            // Positional after the subcommand: a service name. This is the
            // `--rm`-named-service case, and after a `--` terminator the dash
            // check above no longer fires, so the identifier rule is what
            // catches it.
            guard isValidIdentifier(argument) else { return .identifier(argument) }
        }
        guard subcommand != nil else { return .subcommand("") }
        return nil
    }
}
