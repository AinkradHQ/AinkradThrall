import Foundation
import Testing
@testable import ThrallFeature

/// The structural invariants. These match on the **shape** of the guard table,
/// not on tool names, so a future tool pair is covered without touching them.
@MainActor
@Suite("Thrall MCP guard table")
struct ThrallMCPGuardTableTests {
    private var table: [ThrallMCPWriteTools.Tool] { ThrallMCPWriteTools.table }

    /// Anything that injects an argument its safe twin refuses must itself be
    /// gated, or it is an ungated irreversible tool.
    @Test("every injecting tool is destructive")
    func everyInjectingToolIsDestructive() {
        for tool in table where !tool.injects.isEmpty {
            #expect(tool.destructive, Comment(rawValue: "\(tool.name) injects but is not gated"))
        }
    }

    /// Every key a tool rejects must be injected by some twin for the same
    /// operation — otherwise the safe half *deletes* a capability instead of
    /// gating it.
    @Test("every rejected argument has an injecting twin for the same operation")
    func everyRejectedArgumentHasAnInjectingTwin() {
        for tool in table where !tool.rejects.isEmpty {
            let twins = table.filter { $0.operation == tool.operation && $0.name != tool.name }
            #expect(!twins.isEmpty,
                    Comment(rawValue: "\(tool.name) rejects arguments with no twin operation"))
            #expect(twins.contains { !$0.injects.isEmpty },
                    Comment(rawValue: "\(tool.name)'s rejected keys are gated by nothing"))
        }
    }

    /// **The absolute one.** There is no argument shape for "delete 135
    /// volumes" that is safe to hand a language model, and 93 of the 135
    /// volumes on the reference machine were unreferenced — exactly the
    /// population where a wrong call is unrecoverable.
    @Test("no tool can remove a volume, by any route")
    func noToolCanRemoveAVolume() {
        for tool in table {
            // Nothing injects a volume-ish flag.
            for rule in tool.injects {
                #expect(!rule.key.lowercased().contains("volume"),
                        Comment(rawValue: "\(tool.name) injects \(rule.key)"))
            }
            // And no schema advertises a prune.
            let schema = tool.schemaJSON.lowercased()
            #expect(!schema.contains("prune"), Comment(rawValue: "\(tool.name) mentions prune"))
        }
        // And no prune tool exists at all.
        #expect(!table.contains { $0.name.contains("prune") })
    }

    /// The reason the table exists: `destructive` alone cannot express
    /// "destructive by argument".
    /// Goes through `JSONSerialization`, **which is the real path**: a tool
    /// call arrives as a JSON string, so `1` becomes an `NSNumber` and
    /// `as? Bool` accepts it at both the guard and the sink. Written first with
    /// a Swift `Int` literal, which does *not* bridge — so the test passed a
    /// value the model can never actually send and failed for the wrong
    /// reason.
    @Test("removeVolumes is refused as JSON true and as JSON 1",
          arguments: [#"{"stack":"x","removeVolumes":true}"#,
                      #"{"stack":"x","removeVolumes":1}"#])
    func removeVolumesRefused(json: String) {
        let tool = table.first { $0.name == "thrall_stack_down" }!
        let parsed = ThrallMCPServer.object(from: json)
        let (rejection, _) = ThrallMCPWriteTools.vet(tool: tool, arguments: parsed)
        #expect(rejection != nil, Comment(rawValue: "\(json) slipped past the guard"))
        #expect(rejection?.contains("unrecoverable") == true)
    }

    /// A string is refused at the **sink** instead: `as? Bool` fails there, so
    /// the flag is never true and the guard passing it through is correct.
    /// Pinned so a future string-to-bool coercion in the sink fails here first.
    @Test("a string removeVolumes is stopped at the sink, not the guard")
    func removeVolumesAsStringStopsAtTheSink() {
        let tool = table.first { $0.name == "thrall_stack_down" }!
        let (rejection, arguments) = ThrallMCPWriteTools.vet(
            tool: tool,
            arguments: ThrallMCPServer.object(from: #"{"stack":"x","removeVolumes":"true"}"#))
        #expect(rejection == nil)
        #expect(arguments["removeVolumes"] as? Bool == nil,
                "the sink reads this with `as? Bool`, which must fail for a string")
    }

    @Test("removeVolumes false or absent is not treated as a rejection",
          arguments: [#"{"stack":"x","removeVolumes":false}"#,
                      #"{"stack":"x","removeVolumes":0}"#,
                      #"{"stack":"x"}"#])
    func removeVolumesFalseIsFine(json: String) {
        let tool = table.first { $0.name == "thrall_stack_down" }!
        let (rejection, _) = ThrallMCPWriteTools.vet(
            tool: tool, arguments: ThrallMCPServer.object(from: json))
        #expect(rejection == nil, Comment(rawValue: json))
    }

    /// The injecting twin owns the argument outright — it is never taken from
    /// the model.
    @Test("the teardown twin injects its own route, ignoring what was passed")
    func teardownInjectsItsRoute() {
        let tool = table.first { $0.name == "thrall_stack_teardown" }!
        let (rejection, arguments) = ThrallMCPWriteTools.vet(
            tool: tool,
            arguments: ThrallMCPServer.object(from: #"{"stack":"x","byLabel":false}"#))
        #expect(rejection == nil)
        #expect(arguments["byLabel"] as? Bool == true, "the injected value must win")
    }

    /// Restart is ungated deliberately: the service is already broken and
    /// restart is idempotent, so requiring approval to fix it defeats the
    /// point.
    @Test("restart is neither destructive nor guarded")
    func restartIsUngated() {
        let tool = table.first { $0.name == "thrall_restart_service" }!
        #expect(!tool.destructive)
        #expect(tool.rejects.isEmpty && tool.injects.isEmpty)
    }

    @Test("every tool's schema is valid JSON with no additional properties")
    func schemasAreValid() throws {
        for tool in table {
            let data = Data(tool.schemaJSON.utf8)
            let parsed = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Comment(rawValue: "\(tool.name) has an invalid schema"))
            #expect(parsed["type"] as? String == "object")
            // Open schemas let a model pass an argument nothing vets.
            #expect(parsed["additionalProperties"] as? Bool == false,
                    Comment(rawValue: "\(tool.name) accepts unvetted arguments"))
        }
    }

    @Test("tool names are unique and namespaced")
    func namesAreUniqueAndNamespaced() {
        #expect(Set(table.map(\.name)).count == table.count)
        #expect(table.allSatisfy { $0.name.hasPrefix("thrall_") })
    }
}

@MainActor
@Suite("Thrall MCP read surface")
struct ThrallMCPReadTests {
    /// **Hard-capped, and it is not tuning.** An unbounded log tool blows the
    /// context window on call one: 24 services here produce hundreds of lines
    /// a second and one traceback is thousands of lines.
    @Test("the log cap is declared in the schema as well as enforced")
    func logCapIsDeclared() {
        #expect(ThrallMCPServer.maximumLogLines == 200)
        #expect(ThrallMCPServer.maximumLogBytes == 32 * 1024)
    }

    /// A remedy the agent cannot invoke must not name a tool that does not
    /// exist — a model told to call `thrall_pull` would report a failure the
    /// user cannot act on.
    @Test("every remedy tool name is a real published tool")
    func remedyToolNamesResolve() {
        let published = Set(ThrallMCPWriteTools.table.map(\.name))
        let kinds: [ThrallRemedy.Kind] = [
            .restartDependencyThenDependents(dependency: "db", dependents: ["api"]),
            .restartServices(["api"]),
            .upStack,
            .pullStack,
            .teardownByLabel,
        ]
        for kind in kinds {
            guard let name = ThrallMCPServer.toolName(for: kind) else { continue }
            #expect(published.contains(name), Comment(rawValue: "\(name) is not published"))
        }
        // Pull has no tool, and must say so rather than inventing one.
        #expect(ThrallMCPServer.toolName(for: .pullStack) == nil)
    }

    @Test("health labels are stable strings the model can match on")
    func healthLabels() {
        let labels = ThrallStackHealth.allCases.map(ThrallMCPServer.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test("argument parsing survives garbage rather than trapping",
          arguments: ["", "{", "null", "[]", "not json"])
    func argumentParsingIsLenient(json: String) {
        #expect(ThrallMCPServer.object(from: json).isEmpty)
    }

    @Test("payload encoding produces parseable JSON")
    func payloadEncoding() throws {
        let payload = ThrallMCPPayloads.LogPayload(
            container: "abc", lines: ["one", "two"], returnedLines: 2,
            truncated: true, truncationReason: "hit the 32 KB cap")
        let text = ThrallMCPPayloads.encode(payload)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(parsed["returnedLines"] as? Int == 2)
        #expect(parsed["truncated"] as? Bool == true)
    }
}

extension ThrallStackHealth: @retroactive CaseIterable {
    public static var allCases: [ThrallStackHealth] {
        [.down, .allRunning, .partiallyRunning, .stopped, .unhealthy]
    }
}
