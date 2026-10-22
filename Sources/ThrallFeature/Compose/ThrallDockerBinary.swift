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
struct ThrallDockerBinary: Sendable {
    var primaryPath: String
    var fallbackPaths: [String]
    /// The standalone `docker-compose` Thrall's own engine installs. It is the
    /// last resort, used only when no `docker` exists, so a Mac with no other
    /// engine still has compose verbs.
    var standaloneComposePath: String?

    init(
        primaryPath: String = "/usr/local/bin/docker",
        fallbackPaths: [String] = [
            "/opt/homebrew/bin/docker",
            "/usr/bin/docker",
            "/usr/local/bin/docker",
        ],
        standaloneComposePath: String? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".thrall/bin/docker-compose").path
    ) {
        self.primaryPath = primaryPath
        self.fallbackPaths = fallbackPaths
        self.standaloneComposePath = standaloneComposePath
    }

    /// What to spawn for `docker <arguments>`: the `docker` binary, or, for a
    /// `compose` command when there is none, the standalone `docker-compose`
    /// with the leading `compose` dropped. The two take the same arguments
    /// after that word.
    func invocation(for arguments: [String]) -> (executable: String, arguments: [String])? {
        if let docker = resolve() { return (docker, arguments) }
        guard arguments.first == "compose", let standaloneComposePath,
            FileManager.default.isExecutableFile(atPath: standaloneComposePath)
        else { return nil }
        return (standaloneComposePath, Array(arguments.dropFirst()))
    }

    /// The first executable candidate, or nil.
    ///
    /// `PATH` is deliberately **not** consulted. A GUI app's `PATH` is
    /// whatever `launchd` handed it, not the user's shell — so resolving
    /// through it gives a different answer depending on how the app was
    /// started, which is the least debuggable class of bug there is.
    func resolve() -> String? {
        let manager = FileManager.default
        if manager.isExecutableFile(atPath: primaryPath) { return primaryPath }
        return fallbackPaths.first { manager.isExecutableFile(atPath: $0) }
    }

    /// The sentence shown when nothing resolved. Names the paths that were
    /// tried, because "docker not found" with no list is unactionable.
    var notFoundMessage: String {
        let tried = ([primaryPath] + fallbackPaths).uniqued()
        return "No docker binary found. Looked in \(tried.joined(separator: ", ")). "
            + "Thrall needs the CLI for compose commands even though it reads the engine directly."
    }
}
