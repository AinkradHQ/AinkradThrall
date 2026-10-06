import AinkradAppKit
import Foundation

@MainActor
extension ThrallMCPServer {
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
        return AgentActionResult(
            text: ThrallMCPPayloads.encode(detail(for: found, in: model)),
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
            let text = try await client.logTail(
                containerID: container,
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
            return AgentActionResult(
                text: "Could not read logs for \(container): \(error)",
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
}
