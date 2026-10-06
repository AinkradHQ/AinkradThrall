import AinkradAppKit
import Foundation

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
    static func make(
        appID: String,
        model: @escaping @MainActor @Sendable () -> ThrallViewModel
    )
        -> (server: MCPAppServer, failures: [String])
    {
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
        -> [MCPToolSpec]
    {
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
        -> [MCPResourceSpec]
    {
        var incidents = MCPResourceSpec(
            uri: "thrall://incidents",
            title: "Container incidents",
            mimeType: "application/json",
            provider: { await diagnose(model()).text })
        // `purpose` is what tells the agent WHEN to read this rather than
        // leaving it to guess from the title.
        incidents.purpose =
            "Read when the user mentions containers, Docker, compose, a service "
            + "that will not start, or something restarting. Contains the grouped incident list "
            + "with verbatim error text and ordered remedies."
        return [incidents]
    }
}
