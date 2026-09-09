import Foundation

/// JSON the MCP tools return.
///
/// Explicit `Encodable` payloads rather than hand-built strings, because every
/// one of these is read by a language model and a malformed brace turns a
/// diagnosis into a parse error the model then narrates at the user.
enum ThrallMCPPayloads {
    struct EngineSummary: Encodable {
        let name: String
        let endpoint: String
        let isActive: Bool
        let isSupported: Bool
        let apiVersion: String?
        let note: String?
    }

    struct StackSummary: Encodable {
        let name: String
        let id: String
        let workingDirectory: String?
        let health: String
        let containers: Int
        let running: Int
        let exited: Int
        let restarting: Int
        /// Named `configMissing` rather than `orphaned` because the model must
        /// be able to connect it to the sentence in the tool description.
        let configMissing: Bool
        let staleRelativeToConfig: Bool
        let services: [String]
    }

    struct ServiceDetail: Encodable {
        let name: String
        let state: String?
        let declaredButAbsent: Bool
        let dependsOn: [String]
        let containers: [ContainerDetail]
    }

    struct ContainerDetail: Encodable {
        let id: String
        let name: String
        let image: String
        let state: String
        let status: String
    }

    struct StackDetail: Encodable {
        let name: String
        let id: String
        let workingDirectory: String?
        let configFiles: [String]
        let absentConfigFiles: [String]
        let configMissing: Bool
        let health: String
        let services: [ServiceDetail]
        /// Spelled out, because the model cannot otherwise know that `up` and
        /// `pull` are impossible for an orphaned stack.
        let availableActions: [String]
    }

    struct IncidentDetail: Encodable {
        let id: String
        let stack: String
        let headline: String
        let services: [String]
        let containerIDs: [String]
        let exitCode: Int?
        /// The **actual** error text. A paraphrase here is how an agent ends up
        /// confidently describing a failure that did not happen.
        let evidence: String?
        let restartTotal: Int
        let brokenDependency: BrokenDependency?
        let remedies: [RemedyDetail]
    }

    struct BrokenDependency: Encodable {
        let dependent: String
        let dependency: String
        let condition: String
        let state: String
    }

    struct RemedyDetail: Encodable {
        let title: String
        let command: String
        let destroysState: Bool
        let confidence: Int
        /// The tool the model should call to apply it, when one exists.
        let tool: String?
    }

    struct Diagnosis: Encodable {
        let engine: String
        let apiVersion: String?
        let stacks: Int
        let containers: Int
        let running: Int
        let incidents: [IncidentDetail]
        /// Present when there is nothing wrong. A model handed an empty array
        /// with no statement will hedge; a sentence lets it answer plainly.
        let verdict: String
    }

    struct LogPayload: Encodable {
        let container: String
        let lines: [String]
        let returnedLines: Int
        let truncated: Bool
        /// Says why, so the model does not ask again for the same window.
        let truncationReason: String?
    }

    static func encode<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return #"{"error":"Thrall could not encode this result."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
