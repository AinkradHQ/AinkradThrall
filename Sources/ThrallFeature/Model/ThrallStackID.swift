import Foundation

/// What makes a stack *that* stack.
///
/// **`(engine, projectName, workingDirectory)` — the project name alone is not
/// an identity.** Measured on this machine: two unrelated trees both produce
/// the compose project `compose`, so a name-keyed stack merges a
/// `UlynkHomeCloud` deployment with a scratchpad copy of `UlynkControlPlane`
/// and shows one row where there are two projects. Add the engine because the
/// same project name can be running on `orbstack` and on a remote context at
/// once.
///
/// **Merging is on exact equality. There is no fuzzy matching**, by design:
/// every "these are probably the same stack" heuristic eventually merges two
/// that are not, and the failure mode is stopping the wrong database.
public struct ThrallStackID: Hashable, Sendable, CustomStringConvertible {
    /// `ThrallEngineEndpoint.engineKey` — symlink-resolved, so the `default`
    /// and `orbstack` contexts that name the same socket do not double up.
    public let engineKey: String
    /// `com.docker.compose.project`, or nil for the loose-containers
    /// pseudo-stack.
    public let projectName: String?
    /// Canonicalized `com.docker.compose.project.working_dir`. Nil when the
    /// engine did not report one — an older compose, or a project started by
    /// hand.
    public let workingDirectory: ThrallPathKey?

    public init(engineKey: String, projectName: String?, workingDirectory: ThrallPathKey?) {
        self.engineKey = engineKey
        self.projectName = projectName
        self.workingDirectory = workingDirectory
    }

    /// The row that holds every container belonging to no compose project.
    ///
    /// **Rendered as a real stack, never hidden.** Two containers here have no
    /// compose labels at all; a UI that only knows about projects would make
    /// them invisible, and an invisible running container is the worst thing a
    /// container manager can do.
    public static func loose(engineKey: String) -> ThrallStackID {
        ThrallStackID(engineKey: engineKey, projectName: nil, workingDirectory: nil)
    }

    public var isLoose: Bool { projectName == nil }

    public var description: String {
        guard let projectName else { return "\(engineKey)#loose" }
        return "\(engineKey)#\(projectName)@\(workingDirectory?.value ?? "-")"
    }
}
