import SwiftUI
import AinkradAppKit

/// Task S — run one non-interactive command in a container.
///
/// **Argv in, text out, no PTY.** This covers `env`, `cat /etc/hosts`,
/// `nc -z db 5432` — roughly 80% of crash-loop triage — without Thrall
/// containing a terminal emulator. Interactive work is Rune's job, and the
/// empty state says so rather than leaving the user to discover the limit by
/// typing `bash`.
struct RunCommandCard: View {
    @ObservedObject var model: ThrallViewModel

    @Environment(\.ainkradTheme) private var theme
    @State private var containerID: String?
    @State private var commandLine = "env"
    @State private var result: ThrallExecResult?
    @State private var problem: String?
    @State private var isRunning = false

    /// Only running containers: exec against a stopped one fails with a
    /// message about the container not running, which is a worse way to learn
    /// it than not being offered the choice.
    private var candidates: [(id: String, label: String)] {
        model.world.stacks.flatMap { stack in
            stack.services.flatMap { service in
                service.containers
                    .filter { $0.state == .running }
                    .map { (id: $0.id, label: "\(stack.displayName) / \($0.name)") }
            }
        }
        .sorted { $0.label < $1.label }
    }

    var body: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                Text("Run a command")
                    .font(.system(size: 13, weight: .semibold))
                Text("Runs directly in the container — no shell, so no pipes, redirects or "
                     + "variable expansion. Rune handles interactive sessions.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foreground.opacity(0.6))

                if candidates.isEmpty {
                    Text("Nothing is running on \(model.engineLabel).")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foreground.opacity(0.45))
                } else {
                    HStack(spacing: AinkradSpacing.sm) {
                        AinkradMenuButton(items: candidates.map { candidate in
                            AinkradMenuItem(title: candidate.label, systemName: "cube") {
                                containerID = candidate.id
                            }
                        }) {
                            HStack(spacing: AinkradSpacing.xs) {
                                Text(selectedLabel)
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(theme.foreground.opacity(0.4))
                            }
                            .padding(.horizontal, AinkradSpacing.sm)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: AinkradRadius.sm,
                                                         style: .continuous)
                                .fill(theme.foreground.opacity(0.06)))
                        }
                        .fixedSize()

                        AinkradTextField(text: $commandLine, placeholder: "env")
                        AinkradButton(title: "Run", style: .secondary, isLoading: isRunning) {
                            Task { await run() }
                        }
                    }

                    if let problem {
                        // The parser's own sentence, which already explains
                        // what to do instead.
                        Text(problem)
                            .font(.system(size: 11))
                            .foregroundStyle(AinkradStatus.warning
                                .color(in: theme, statusColors: .init()))
                    }
                    if let result {
                        output(result)
                    }
                }
            }
        }
    }

    private var selectedLabel: String {
        guard let containerID,
              let match = candidates.first(where: { $0.id == containerID }) else {
            return candidates.first?.label ?? "No container"
        }
        return match.label
    }

    @ViewBuilder
    private func output(_ result: ThrallExecResult) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradBadge(text: result.exitCode.map { "exit \($0)" } ?? "exit unknown",
                             status: result.succeeded ? .success : .danger)
                if result.truncated {
                    AinkradBadge(text: "output truncated", status: .warning)
                }
            }
            if !result.stdout.isEmpty {
                AinkradCodeBlock(result.stdout)
            }
            if !result.stderr.isEmpty {
                // Kept separate, which is the whole reason the exec stream is
                // demultiplexed rather than concatenated.
                Text("stderr")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.foreground.opacity(0.5))
                AinkradCodeBlock(result.stderr)
            }
            if result.stdout.isEmpty && result.stderr.isEmpty {
                Text("No output.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foreground.opacity(0.45))
            }
        }
    }

    private func run() async {
        problem = nil
        result = nil
        guard let client = model.engineClient else {
            problem = "No engine is selected."
            return
        }
        let target = containerID ?? candidates.first?.id
        guard let target else {
            problem = "Choose a container."
            return
        }
        do {
            let command = try ThrallExecRunner.parse(commandLine: commandLine)
            isRunning = true
            result = try await ThrallExecRunner(client: client)
                .run(containerID: target, command: command)
            isRunning = false
        } catch let error as ThrallExecError {
            isRunning = false
            problem = Self.describe(error)
        } catch {
            isRunning = false
            problem = "\(error)"
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
