import Foundation

/// Finds the `docker` binary, or fails with something the user can act on.
///
/// **Fail closed.** On this machine `/usr/local/bin/docker` is a symlink into
/// `OrbStack.app`, and `~/.docker/cli-plugins/docker-compose` is another —
/// removing OrbStack removes both, and `docker compose` stops existing while
/// the *socket* may still be served by something else. So a missing binary is
/// a distinct, explained state, never an empty result or a crash.
///
/// Follows `Ainkrad`'s own `DockerBackend`: a primary path plus ordered
/// fallbacks, with tests injecting a nonexistent primary and `fallbackPaths:
/// []` to force the failure deterministically.
public struct ThrallDockerBinary: Sendable {
    public var primaryPath: String
    public var fallbackPaths: [String]

    public init(primaryPath: String = "/usr/local/bin/docker",
                fallbackPaths: [String] = ["/opt/homebrew/bin/docker",
                                           "/usr/bin/docker",
                                           "/usr/local/bin/docker"]) {
        self.primaryPath = primaryPath
        self.fallbackPaths = fallbackPaths
    }

    /// The first executable candidate, or nil.
    ///
    /// `PATH` is deliberately **not** consulted. A GUI app's `PATH` is
    /// whatever `launchd` handed it, not the user's shell — so resolving
    /// through it gives a different answer depending on how the app was
    /// started, which is the least debuggable class of bug there is.
    public func resolve() -> String? {
        let manager = FileManager.default
        if manager.isExecutableFile(atPath: primaryPath) { return primaryPath }
        return fallbackPaths.first { manager.isExecutableFile(atPath: $0) }
    }

    /// The sentence shown when nothing resolved. Names the paths that were
    /// tried, because "docker not found" with no list is unactionable.
    public var notFoundMessage: String {
        let tried = ([primaryPath] + fallbackPaths).reduced()
        return "No docker binary found. Looked in \(tried.joined(separator: ", ")). "
            + "Thrall needs the CLI for compose commands even though it reads the engine directly."
    }
}

private extension Array where Element == String {
    /// Order-preserving dedupe, so a primary that repeats in the fallbacks is
    /// listed once.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
