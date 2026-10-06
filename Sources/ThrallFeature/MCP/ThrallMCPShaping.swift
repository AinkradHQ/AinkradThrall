import AinkradAppKit
import Foundation

@MainActor
extension ThrallMCPServer {
    // MARK: - Shaping

    static func detail(for stack: ThrallStack, in model: ThrallViewModel)
        -> ThrallMCPPayloads.StackDetail
    {
        ThrallMCPPayloads.StackDetail(
            name: stack.displayName,
            id: stack.id.description,
            workingDirectory: stack.workingDirectoryDisplay,
            configFiles: stack.configFiles,
            absentConfigFiles: stack.absentConfigFiles,
            configMissing: stack.isConfigMissing,
            health: label(stack.health),
            services: stack.services.map { service in
                ThrallMCPPayloads.ServiceDetail(
                    name: service.name,
                    state: service.worstState?.label,
                    declaredButAbsent: service.isDeclaredButAbsent,
                    dependsOn: service.dependsOn.map(\.service),
                    containers: service.containers.map {
                        ThrallMCPPayloads.ContainerDetail(
                            id: $0.id, name: $0.name, image: $0.image,
                            state: $0.state.label, status: $0.statusText)
                    })
            },
            availableActions: model.actions(for: stack).map(\.title))
    }

    static func detail(for incident: ThrallIncident, in world: ThrallWorld)
        -> ThrallMCPPayloads.IncidentDetail
    {
        let stack = world.stack(incident.key.stack)
        return ThrallMCPPayloads.IncidentDetail(
            id: incident.id,
            stack: incident.stackName,
            headline: incident.headline,
            services: incident.services,
            containerIDs: incident.containerIDs,
            exitCode: incident.exitCode,
            evidence: incident.evidence,
            restartTotal: incident.restartTotal,
            brokenDependency: incident.brokenDependencies.first.map {
                ThrallMCPPayloads.BrokenDependency(
                    dependent: $0.dependent,
                    dependency: $0.dependency,
                    condition: $0.condition,
                    state: $0.stateLabel)
            },
            remedies: ThrallRemedy.remedies(for: incident, stack: stack).map { remedy in
                ThrallMCPPayloads.RemedyDetail(
                    title: remedy.title,
                    command: remedy.commandPreview,
                    destroysState: remedy.destroysState,
                    confidence: remedy.confidence,
                    tool: toolName(for: remedy.kind))
            })
    }

    /// Which write tool applies a remedy. Nil where none does — a remedy the
    /// agent cannot invoke must not claim a tool that does not exist.
    static func toolName(for kind: ThrallRemedy.Kind) -> String? {
        switch kind {
        case .restartDependencyThenDependents, .restartServices: return "thrall_restart_service"
        case .upStack: return "thrall_stack_up"
        case .pullStack: return nil
        case .teardownByLabel: return "thrall_stack_teardown"
        }
    }

    static func label(_ health: ThrallStackHealth) -> String {
        switch health {
        case .down: return "down"
        case .allRunning: return "all running"
        case .partiallyRunning: return "partially running"
        case .stopped: return "stopped"
        case .unhealthy: return "unhealthy"
        }
    }

    static func unsupportedReason(_ endpoint: ThrallEngineEndpoint) -> String? {
        if case .unsupported(_, _, let reason) = endpoint { return reason }
        return nil
    }

    static func object(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return parsed
    }

    static func noEngine(_ model: ThrallViewModel) -> AgentActionResult {
        AgentActionResult(
            text: "No container engine is selected. \(model.contextNotes.joined(separator: " "))",
            isError: true)
    }
}
