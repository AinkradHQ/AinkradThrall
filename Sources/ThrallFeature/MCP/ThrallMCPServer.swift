import Foundation
import AinkradAppKit

/// Thrall's MCP surface — **the only front door the assistant has.**
///
/// No `AgentActionProvider` actions are registered, deliberately. GitMage
/// deleted its `git_op` action seam once MCP existed, and two seams onto the
/// same capability means two places to forget a guard.
///
/// ## The read half
///
/// `thrall_diagnose` is the flagship: one call answers "what is wrong with my
/// machine". It is the tool that makes Thrall worth having in an Agentic OS,
/// because the answer it gives is the *collapsed* one — "pgsql is exited, 12
/// services blocked" — rather than a list of red containers the model then has
/// to correlate itself.
///
/// `thrall_logs` is **hard-capped at 200 lines / 32 KB**, and that is not
/// tuning. An unbounded log tool blows the context window on call one: 24
/// services here produce hundreds of lines a second, and a single `aai1058`
/// traceback is thousands of lines on its own.
@MainActor
enum ThrallMCPServer {
    static let maximumLogLines = 200
    static let maximumLogBytes = 32 * 1024

    /// Builds the server. Returns the dropped tool names alongside it: a tool
    /// the host refuses is a silently missing capability, so the caller logs
    /// it rather than letting the assistant simply never see it.
    static func make(appID: String,
                     model: @escaping @MainActor @Sendable () -> ThrallViewModel)
        -> (server: MCPAppServer, failures: [String]) {
        let server = MCPAppServer(appID: appID)
        var failures: [String] = []

        for tool in readTools(model: model) {
            if !server.addTool(tool) { failures.append(tool.name) }
        }
        for tool in ThrallMCPWriteTools.specs(model: model) {
            if !server.addTool(tool) { failures.append(tool.name) }
        }
        for resource in resources(model: model) {
            if !server.addResource(resource) { failures.append(resource.uri) }
        }
        return (server, failures)
    }

    // MARK: - Read tools

    private static func readTools(model: @escaping @MainActor @Sendable () -> ThrallViewModel)
        -> [MCPToolSpec] {
        [
            MCPToolSpec(
                name: "thrall_diagnose",
                description: """
                    Answer "what is wrong with my container setup" in one call. Returns the \
                    crash-looping services on the active engine, already GROUPED into incidents: \
                    twelve workers failing on the same error are one incident with twelve \
                    members, not twelve problems. Each incident carries the verbatim error text, \
                    the depends_on verdict where one applies (e.g. api needs db; db is exited), \
                    and remedies ordered by confidence. Call this FIRST when asked about \
                    containers being broken, slow to start, or restarting.
                    """,
                schemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
                readOnly: true,
                handler: { _ in await diagnose(model()) }),

            MCPToolSpec(
                name: "thrall_stacks",
                description: """
                    List the compose stacks on the active engine with per-state container counts \
                    and health. `configMissing: true` means the stack is running but its compose \
                    file is gone from disk — `docker compose` cannot touch such a stack at all, \
                    so up/down/pull are impossible for it and only engine-level container verbs \
                    work.
                    """,
                schemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
                readOnly: true,
                handler: { _ in await stacks(model()) }),

            MCPToolSpec(
                name: "thrall_stack",
                description: """
                    Detail on one stack: its services, their containers and states, its compose \
                    files and which of them are missing, and the actions actually available for \
                    it. Use after `thrall_stacks` when you need container ids or the dependency \
                    graph. `name` matches the stack name; if two stacks share a name (which \
                    happens — the project name is not unique), pass the `id` from \
                    `thrall_stacks` instead.
                    """,
                schemaJSON: """
                    {"type":"object","properties":{\
                    "name":{"type":"string","description":"Stack (compose project) name."},\
                    "id":{"type":"string","description":"Exact stack id from thrall_stacks."}},\
                    "additionalProperties":false}
                    """,
                readOnly: true,
                handler: { arguments in await stack(model(), arguments: arguments) }),

            MCPToolSpec(
                name: "thrall_logs",
                description: """
                    The tail of one container's log. Capped at \(maximumLogLines) lines and \
                    \(maximumLogBytes / 1024) KB per call — ask for a specific container from \
                    `thrall_stack`, not for a whole stack. Defaults to stderr only, which is \
                    where a dying process writes its reason; pass `includeStdout: true` when you \
                    need the surrounding output.
                    """,
                schemaJSON: """
                    {"type":"object","properties":{\
                    "container":{"type":"string","description":"Container id or name."},\
                    "lines":{"type":"integer","minimum":1,"maximum":\(maximumLogLines),\
                    "description":"Lines to return. Clamped to \(maximumLogLines)."},\
                    "includeStdout":{"type":"boolean","description":"Include stdout as well as stderr."}},\
                    "required":["container"],"additionalProperties":false}
                    """,
                readOnly: true,
                handler: { arguments in await logs(model(), arguments: arguments) }),

            MCPToolSpec(
                name: "thrall_engines",
                description: """
                    The container engines Thrall can see (Docker contexts), which one is active, \
                    and why any is unusable. Two contexts can name the same daemon through \
                    different socket paths, so check here before concluding a container is \
                    missing.
                    """,
                schemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
                readOnly: true,
                handler: { _ in await engines(model()) }),
        ]
    }

    // MARK: - Resources

    private static func resources(model: @escaping @MainActor @Sendable () -> ThrallViewModel)
        -> [MCPResourceSpec] {
        var incidents = MCPResourceSpec(
            uri: "thrall://incidents",
            title: "Container incidents",
            mimeType: "application/json",
            provider: { await diagnose(model()).text })
        // `purpose` is what tells the agent WHEN to read this rather than
        // leaving it to guess from the title.
        incidents.purpose = "Read when the user mentions containers, Docker, compose, a service "
            + "that will not start, or something restarting. Contains the grouped incident list "
            + "with verbatim error text and ordered remedies."
        return [incidents]
    }

    // MARK: - Handlers

    static func diagnose(_ model: ThrallViewModel) async -> AgentActionResult {
        guard model.activeContext != nil else { return noEngine(model) }
        let world = model.world
        let incidents = model.triage.incidents
        let running = world.stacks.reduce(0) { $0 + $1.breakdown.running }
        let containers = world.stacks.reduce(0) { $0 + $1.containerCount }

        let payload = ThrallMCPPayloads.Diagnosis(
            engine: model.engineLabel,
            apiVersion: model.engineVersion?.negotiated.description,
            stacks: world.stacks.count,
            containers: containers,
            running: running,
            incidents: incidents.map { detail(for: $0, in: world) },
            verdict: incidents.isEmpty
                ? "Nothing is crash-looping on \(model.engineLabel). "
                    + "\(running) of \(containers) containers are running across "
                    + "\(world.stacks.count) stacks."
                : "\(incidents.count) incident\(incidents.count == 1 ? "" : "s") affecting "
                    + "\(incidents.reduce(0) { $0 + $1.memberCount }) containers.")
        return AgentActionResult(text: ThrallMCPPayloads.encode(payload), isError: false)
    }

    static func stacks(_ model: ThrallViewModel) async -> AgentActionResult {
        guard model.activeContext != nil else { return noEngine(model) }
        let payload = model.world.stacks.map { stack in
            ThrallMCPPayloads.StackSummary(
                name: stack.displayName,
                id: stack.id.description,
                workingDirectory: stack.workingDirectoryDisplay,
                health: label(stack.health),
                containers: stack.containerCount,
                running: stack.breakdown.running,
                exited: stack.breakdown.exited,
                restarting: stack.breakdown.restarting,
                configMissing: stack.isConfigMissing,
                staleRelativeToConfig: stack.isStaleRelativeToConfig,
                services: stack.services.map(\.name))
        }
        return AgentActionResult(text: ThrallMCPPayloads.encode(payload), isError: false)
    }

    static func stack(_ model: ThrallViewModel, arguments: String) async -> AgentActionResult {
        guard model.activeContext != nil else { return noEngine(model) }
        let args = object(from: arguments)
        let identifier = args["id"] as? String
        let name = args["name"] as? String
        guard identifier != nil || name != nil else {
            return AgentActionResult(text: "Pass either `name` or `id`.", isError: true)
        }
        let matches = model.world.stacks.filter { stack in
            if let identifier { return stack.id.description == identifier }
            return stack.displayName == name
        }
        guard let found = matches.first else {
            return AgentActionResult(
                text: "No stack matches \(identifier ?? name ?? ""). "
                    + "Known stacks: \(model.world.stacks.map(\.displayName).joined(separator: ", "))",
                isError: true)
        }
        // The project name genuinely is not unique — two unrelated trees can
        // both produce `compose`. Saying so is better than silently picking one.
        guard matches.count == 1 else {
            return AgentActionResult(
                text: "\(matches.count) stacks are named \(name ?? ""). Pass one of these ids "
                    + "instead: \(matches.map(\.id.description).joined(separator: ", "))",
                isError: true)
        }
        return AgentActionResult(text: ThrallMCPPayloads.encode(detail(for: found, in: model)),
                                 isError: false)
    }

    static func logs(_ model: ThrallViewModel, arguments: String) async -> AgentActionResult {
        guard let client = model.engineClient else { return noEngine(model) }
        let args = object(from: arguments)
        guard let container = args["container"] as? String, !container.isEmpty else {
            return AgentActionResult(text: "`container` is required.", isError: true)
        }
        let requested = (args["lines"] as? Int) ?? 60
        let wanted = min(max(1, requested), maximumLogLines)
        let includeStdout = (args["includeStdout"] as? Bool) ?? false
        do {
            let text = try await client.logTail(containerID: container,
                                                lines: wanted,
                                                stderrOnly: !includeStdout)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var truncated = false
            var reason: String?
            if lines.count > wanted {
                lines = Array(lines.suffix(wanted))
                truncated = true
                reason = "kept the last \(wanted) lines"
            }
            // The byte cap is second and independent: 200 lines of minified
            // JSON is still tens of thousands of tokens.
            var bytes = 0
            var kept: [String] = []
            for line in lines.reversed() {
                bytes += line.utf8.count + 1
                if bytes > maximumLogBytes {
                    truncated = true
                    reason = "hit the \(maximumLogBytes / 1024) KB cap"
                    break
                }
                kept.insert(line, at: 0)
            }
            let payload = ThrallMCPPayloads.LogPayload(
                container: container, lines: kept, returnedLines: kept.count,
                truncated: truncated, truncationReason: reason)
            return AgentActionResult(text: ThrallMCPPayloads.encode(payload), isError: false)
        } catch {
            return AgentActionResult(text: "Could not read logs for \(container): \(error)",
                                     isError: true)
        }
    }

    static func engines(_ model: ThrallViewModel) async -> AgentActionResult {
        let active = model.activeContext?.name
        let payload = model.contexts.map { context in
            ThrallMCPPayloads.EngineSummary(
                name: context.name,
                endpoint: context.endpoint.displayString,
                isActive: context.name == active,
                isSupported: context.isSupported,
                apiVersion: context.name == active
                    ? model.engineVersion?.negotiated.description : nil,
                note: unsupportedReason(context.endpoint))
        }
        return AgentActionResult(text: ThrallMCPPayloads.encode(payload), isError: false)
    }

    // MARK: - Shaping

    static func detail(for stack: ThrallStack, in model: ThrallViewModel)
        -> ThrallMCPPayloads.StackDetail {
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
        -> ThrallMCPPayloads.IncidentDetail {
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
                ThrallMCPPayloads.BrokenDependency(dependent: $0.dependent,
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
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
