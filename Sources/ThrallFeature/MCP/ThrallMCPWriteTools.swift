import Foundation
import AinkradAppKit

/// The write half of Thrall's MCP surface, and its guard table.
///
/// ## Why a reject/inject table rather than a `destructive` flag per tool
///
/// Copied from `GitMageMCPServer`, which needed it for the same reason: a
/// static per-tool flag cannot express **"destructive by argument"**.
/// `thrall_stack_down` is safe; `thrall_stack_down` with `removeVolumes` is
/// unrecoverable. So the safe tool *rejects* the argument and a separate,
/// `destructive: true` twin *injects* it itself — the argument never comes
/// from the model at all.
///
/// Two invariants hold across the table and are checked **structurally**, so a
/// future pair is covered without touching the tests:
///
///  * `everyInjectingToolIsDestructive` — anything that injects must be
///    `destructive: true`, or it is an ungated irreversible tool.
///  * `everyRejectedArgumentHasAnInjectingTwin` — every key a tool rejects
///    must be injected by some twin, or the safe half *deletes* a capability
///    instead of gating it.
///
/// ## What is deliberately absent
///
/// **There is no volume-prune or system-prune tool at all**, and no tool that
/// can remove a volume by any route. There is no argument shape for "delete
/// 135 volumes" that is safe to hand a language model: 93 of the 135 volumes
/// on the reference machine were unreferenced, which is exactly the population
/// where a wrong call is unrecoverable. Volume deletion stays human-in-UI.
/// `noToolCanRemoveAVolume` asserts it.
@MainActor
enum ThrallMCPWriteTools {
    /// One guarded argument.
    struct GuardRule: Equatable {
        let key: String
        let value: Value

        init(_ key: String, _ value: Value) {
            self.key = key
            self.value = value
        }

        /// Exact matches only, which is safe **because the sinks are exact
        /// too**: every one of these keys is read with `as? Bool`, and `1`
        /// bridges to `NSNumber` which `as? Bool` accepts at both ends, so the
        /// guard catches it. If a handler is ever made more tolerant — a
        /// string-to-bool coercion, an alias — the rule must be widened in
        /// lockstep or the ungated tool becomes a live volume deletion.
        enum Value: Equatable {
            case bool(Bool)

            var foundation: Any {
                switch self { case .bool(let flag): return flag }
            }

            func matches(_ candidate: Any?) -> Bool {
                switch self {
                case .bool(let flag): return (candidate as? Bool) == flag
                }
            }
        }
    }

    /// One published tool.
    struct Tool {
        let name: String
        let summary: String
        let schemaJSON: String
        let destructive: Bool
        var rejects: [GuardRule] = []
        var injects: [GuardRule] = []
        /// The operation both halves of a pair share, so the structural test
        /// can find a twin without matching on names.
        let operation: String
    }

    /// The whole write surface, as data. Being a table rather than five
    /// `addTool` calls is what makes the invariants testable.
    static let table: [Tool] = [
        Tool(name: "thrall_restart_service",
             summary: """
                 Restart the containers of one service, or of a whole stack when `service` is \
                 omitted. **Ungated and unconfirmed on purpose**: the service is already broken \
                 and restart is idempotent, so requiring approval to fix it would defeat the \
                 point. Use this as the first remedy for a crash loop, and restart the failing \
                 DEPENDENCY before its dependents.
                 """,
             schemaJSON: """
                 {"type":"object","properties":{\
                 "stack":{"type":"string","description":"Stack name or id from thrall_stacks."},\
                 "service":{"type":"string","description":"Service to restart. Omit for the whole stack."}},\
                 "required":["stack"],"additionalProperties":false}
                 """,
             destructive: false,
             operation: "restart"),

        Tool(name: "thrall_stack_up",
             summary: """
                 Bring a stack up (`docker compose up -d --remove-orphans`). Fails for a stack \
                 whose compose file is gone — check `configMissing` from `thrall_stacks` first.
                 """,
             schemaJSON: """
                 {"type":"object","properties":{\
                 "stack":{"type":"string","description":"Stack name or id."}},\
                 "required":["stack"],"additionalProperties":false}
                 """,
             destructive: false,
             operation: "up"),

        Tool(name: "thrall_stack_down",
             summary: """
                 Stop and remove a stack's containers (`docker compose down`). **Named volumes \
                 are kept** — this tool cannot remove one, in any spelling. Ask the user to do \
                 that in Thrall's UI if it is genuinely wanted.
                 """,
             schemaJSON: """
                 {"type":"object","properties":{\
                 "stack":{"type":"string","description":"Stack name or id."},\
                 "removeVolumes":{"type":"boolean","description":"Refused. Volume removal is not available to tools."}},\
                 "required":["stack"],"additionalProperties":false}
                 """,
             destructive: true,
             rejects: [GuardRule("removeVolumes", .bool(true))],
             operation: "down"),

        Tool(name: "thrall_stack_teardown",
             summary: """
                 Tear down a stack whose compose file is gone, by matching the compose project \
                 label through the Engine API. This is the ONLY way to clean up such a stack — \
                 `docker compose down` needs the file the stack was started from. Volumes are \
                 not touched.
                 """,
             schemaJSON: """
                 {"type":"object","properties":{\
                 "stack":{"type":"string","description":"Stack name or id."}},\
                 "required":["stack"],"additionalProperties":false}
                 """,
             destructive: true,
             // The safe twin of `removeVolumes`: this operation injects
             // `byLabel` itself rather than accepting a route from the model.
             injects: [GuardRule("byLabel", .bool(true))],
             operation: "down"),
    ]

    /// Rejects an argument the tool refuses, or injects the ones it owns.
    /// Returns nil when the call may proceed, with `arguments` rewritten.
    static func vet(tool: Tool, arguments: [String: Any])
        -> (rejection: String?, arguments: [String: Any]) {
        for rule in tool.rejects where rule.value.matches(arguments[rule.key]) {
            return ("\(tool.name) refuses \(rule.key). "
                + volumeExplanation(for: rule.key), arguments)
        }
        var rewritten = arguments
        // ALL listed values are injected: the destructive twin owns every
        // argument its safe counterpart refuses.
        for rule in tool.injects { rewritten[rule.key] = rule.value.foundation }
        return (nil, rewritten)
    }

    private static func volumeExplanation(for key: String) -> String {
        guard key.lowercased().contains("volume") else {
            return "Ask the user to do it in Thrall."
        }
        return "Deleting a volume is not something a tool can do in Thrall — it is the one "
            + "unrecoverable operation here. Ask the user to do it in the Storage area, where "
            + "the exact volumes are listed by name first."
    }

    /// Builds the specs, wrapping each handler in the guard.
    static func specs(model: @escaping @MainActor @Sendable () -> ThrallViewModel)
        -> [MCPToolSpec] {
        table.map { tool in
            MCPToolSpec(
                name: tool.name,
                description: tool.summary,
                schemaJSON: tool.schemaJSON,
                destructive: tool.destructive,
                readOnly: false,
                handler: { arguments in
                    let parsed = ThrallMCPServer.object(from: arguments)
                    let (rejection, vetted) = vet(tool: tool, arguments: parsed)
                    if let rejection {
                        return AgentActionResult(text: rejection, isError: true)
                    }
                    return await run(tool: tool, arguments: vetted, model: model())
                })
        }
    }

    // MARK: - Execution

    static func run(tool: Tool, arguments: [String: Any],
                    model: ThrallViewModel) async -> AgentActionResult {
        guard let identifier = arguments["stack"] as? String, !identifier.isEmpty else {
            return AgentActionResult(text: "`stack` is required.", isError: true)
        }
        let matches = model.world.stacks.filter {
            $0.displayName == identifier || $0.id.description == identifier
        }
        guard let stack = matches.first else {
            return AgentActionResult(
                text: "No stack matches \(identifier). Known: "
                    + model.world.stacks.map(\.displayName).joined(separator: ", "),
                isError: true)
        }
        guard matches.count == 1 else {
            return AgentActionResult(
                text: "\(matches.count) stacks are named \(identifier); pass an id instead: "
                    + matches.map(\.id.description).joined(separator: ", "),
                isError: true)
        }

        switch tool.operation {
        case "restart":
            // An orphaned stack gets the engine-level verb, because compose
            // cannot reach it. Choosing here rather than in the schema keeps
            // the model from having to know the difference.
            model.perform(stack.isConfigMissing ? .engineRestart : .restart, on: stack)
            return AgentActionResult(
                text: "Restarting \(stack.displayName)"
                    + (stack.isConfigMissing ? " through the engine (its compose file is gone)."
                       : " with docker compose."),
                isError: false)
        case "up":
            guard !stack.isConfigMissing else {
                return AgentActionResult(
                    text: "\(stack.displayName)'s compose file is gone, so it cannot be brought "
                        + "up. Use thrall_stack_teardown to clean it up, or thrall_restart_service "
                        + "to restart what is still there.",
                    isError: true)
            }
            model.perform(.up, on: stack)
            return AgentActionResult(text: "Bringing \(stack.displayName) up.", isError: false)
        case "down":
            if arguments["byLabel"] as? Bool == true {
                model.pendingTeardown = stack
                model.confirmPendingTeardown()
                return AgentActionResult(
                    text: "Tearing \(stack.displayName) down by label. Volumes are untouched.",
                    isError: false)
            }
            model.perform(.down, on: stack)
            return AgentActionResult(
                text: "Taking \(stack.displayName) down. Named volumes are kept.",
                isError: false)
        default:
            return AgentActionResult(text: "\(tool.name) is not implemented.", isError: true)
        }
    }
}
