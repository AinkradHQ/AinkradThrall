import Foundation

/// One "Run a command" invocation from the containers area, checked and ready
/// to run.
///
/// Out of `RunCommandCard` so the view only holds state: the checks and the
/// error wording live here, beside the runner they front.
struct ThrallRunCommand {
    /// A sentence for the card, already phrased for the user.
    struct Problem: Error, Equatable {
        let message: String
    }

    let client: ThrallEngineClient
    let containerID: String
    let command: [String]

    /// Checks there is an engine and a container, then parses the line. The
    /// parse is the only step that can refuse what the user typed.
    static func prepare(
        commandLine: String, containerID: String?, client: ThrallEngineClient?
    ) -> Result<ThrallRunCommand, Problem> {
        guard let client else { return .failure(Problem(message: "No engine is selected.")) }
        guard let containerID else { return .failure(Problem(message: "Choose a container.")) }
        do {
            let command = try ThrallExecRunner.parse(commandLine: commandLine)
            return .success(ThrallRunCommand(client: client, containerID: containerID, command: command))
        } catch let error as ThrallExecError {
            return .failure(Problem(message: describe(error)))
        } catch {
            return .failure(Problem(message: "\(error)"))
        }
    }

    func execute() async -> Result<ThrallExecResult, Problem> {
        do {
            return .success(
                try await ThrallExecRunner(client: client)
                    .run(containerID: containerID, command: command))
        } catch let error as ThrallExecError {
            return .failure(Problem(message: Self.describe(error)))
        } catch {
            return .failure(Problem(message: "\(error)"))
        }
    }

    static func describe(_ error: ThrallExecError) -> String {
        switch error {
        case .emptyCommand: return "Type a command."
        case .invalidArgument(let message): return message
        case .tooManyArguments(let count):
            return "\(count) arguments is more than a diagnostic command needs "
                + "(the limit is \(ThrallExecRunner.maximumArguments))."
        case .engine(let message): return message
        }
    }
}
