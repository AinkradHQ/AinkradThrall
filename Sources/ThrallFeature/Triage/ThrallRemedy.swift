import Foundation

/// Something the user can do about an incident, with the exact command it will
/// run shown before it runs.
///
/// **Ordered by decreasing confidence**, and the ordering is the advice. A
/// remedy list sorted by convenience teaches nothing; sorted by confidence it
/// says "this is almost certainly it" and then "if not, try this".
///
/// **Confirmation is only for what destroys state.** Restarting an already
/// broken service is idempotent and does not confirm — gating the action that
/// *fixes* the problem is what makes people stop using the tool.
public struct ThrallRemedy: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Restart the failing dependency, then the services waiting on it.
        /// The highest-confidence remedy whenever there is a verdict, because
        /// the dependency being down *is* the diagnosis.
        case restartDependencyThenDependents(dependency: String, dependents: [String])
        /// Restart the failing services themselves.
        case restartServices([String])
        /// Bring the whole stack up — recreates anything missing.
        case upStack
        /// Re-pull the image, for a failure that looks like a bad or partial
        /// image.
        case pullStack
        /// Tear an orphaned stack down by label, through the Engine API.
        /// Works precisely *because* it does not need the compose file that
        /// `docker compose down` demands.
        case teardownByLabel
    }

    public let kind: Kind
    /// Higher is more confident. Only used for ordering.
    public let confidence: Int
    public let title: String
    /// The literal command, shown before it runs. A remedy the user cannot
    /// read is a remedy they cannot trust.
    public let commandPreview: String
    public let destroysState: Bool

    public var id: String { title }

    /// Builds the remedy list for an incident.
    public static func remedies(for incident: ThrallIncident,
                                stack: ThrallStack?) -> [ThrallRemedy] {
        var found: [ThrallRemedy] = []
        let project = stack?.displayName ?? incident.stackName

        // Highest confidence: there is a named dependency and it is down.
        if let verdict = incident.brokenDependencies.first {
            let dependents = incident.services.filter { $0 != verdict.dependency }
            found.append(ThrallRemedy(
                kind: .restartDependencyThenDependents(dependency: verdict.dependency,
                                                       dependents: dependents),
                confidence: 100,
                title: "Restart \(verdict.dependency), then \(dependents.count) dependent"
                    + "\(dependents.count == 1 ? "" : "s")",
                commandPreview: "docker compose -p \(project) restart -- \(verdict.dependency)\n"
                    + "docker compose -p \(project) restart -- "
                    + dependents.joined(separator: " "),
                destroysState: false))
        }

        let isOrphaned = stack?.isConfigMissing ?? false
        if isOrphaned {
            // Compose cannot touch an orphan at all, so the engine-level
            // restart is what is on offer.
            found.append(ThrallRemedy(
                kind: .restartServices(incident.services),
                confidence: 70,
                title: "Restart \(incident.services.count) container"
                    + "\(incident.services.count == 1 ? "" : "s") through the engine",
                commandPreview: incident.containerIDs.prefix(3)
                    .map { "POST /containers/\($0.prefix(12))/restart" }
                    .joined(separator: "\n")
                    + (incident.containerIDs.count > 3
                       ? "\n… and \(incident.containerIDs.count - 3) more" : ""),
                destroysState: false))
            found.append(ThrallRemedy(
                kind: .teardownByLabel,
                confidence: 20,
                title: "Tear this stack down by label",
                commandPreview: "POST /containers/{id}/stop for every container labelled\n"
                    + "com.docker.compose.project=\(project)\n"
                    + "then DELETE /containers/{id}",
                destroysState: true))
        } else {
            found.append(ThrallRemedy(
                kind: .restartServices(incident.services),
                confidence: 60,
                title: "Restart \(incident.services.count) failing service"
                    + "\(incident.services.count == 1 ? "" : "s")",
                commandPreview: "docker compose -p \(project) restart -- "
                    + incident.services.joined(separator: " "),
                destroysState: false))
            found.append(ThrallRemedy(
                kind: .upStack,
                confidence: 40,
                title: "Bring \(project) up",
                commandPreview: "docker compose -p \(project) up -d --remove-orphans",
                destroysState: false))
            // Only offered where the evidence points at the image rather than
            // at a dependency.
            if incident.brokenDependencies.isEmpty {
                found.append(ThrallRemedy(
                    kind: .pullStack,
                    confidence: 25,
                    title: "Re-pull \(project)'s images",
                    commandPreview: "docker compose -p \(project) pull",
                    destroysState: false))
            }
        }
        return found.sorted { $0.confidence > $1.confidence }
    }
}
