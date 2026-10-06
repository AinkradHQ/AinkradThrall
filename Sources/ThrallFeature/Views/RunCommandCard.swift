import AinkradAppKit
import SwiftUI

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
    @Environment(\.ainkradStatusColors) private var statusColors
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
                AinkradCaption(
                    "Runs directly in the container — no shell, so no pipes, redirects or "
                        + "variable expansion. Rune handles interactive sessions.")

                if candidates.isEmpty {
                    AinkradCaption("Nothing is running on \(model.engineLabel).")
                } else {
                    HStack(spacing: AinkradSpacing.sm) {
                        AinkradMenuButton(
                            items: candidates.map { candidate in
                                AinkradMenuItem(title: candidate.label, systemName: "cube") {
                                    containerID = candidate.id
                                }
                            }
                        ) {
                            HStack(spacing: AinkradSpacing.xs) {
                                Text(selectedLabel)
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(theme.foreground.opacity(0.4))
                            }
                            .padding(.horizontal, AinkradSpacing.sm)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: AinkradRadius.sm,
                                    style: .continuous
                                )
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
                            .foregroundStyle(
                                AinkradStatus.warning
                                    .color(in: theme, statusColors: statusColors))
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
            let match = candidates.first(where: { $0.id == containerID })
        else {
            return candidates.first?.label ?? "No container"
        }
        return match.label
    }

    @ViewBuilder
    private func output(_ result: ThrallExecResult) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack(spacing: AinkradSpacing.sm) {
                AinkradBadge(
                    text: result.exitCode.map { "exit \($0)" } ?? "exit unknown",
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
                AinkradCaption("No output.")
            }
        }
    }

    private func run() async {
        problem = nil
        result = nil
        let prepared = ThrallRunCommand.prepare(
            commandLine: commandLine,
            containerID: containerID ?? candidates.first?.id,
            client: model.engineClient)
        switch prepared {
        case .failure(let failure):
            problem = failure.message
        case .success(let invocation):
            isRunning = true
            let outcome = await invocation.execute()
            isRunning = false
            switch outcome {
            case .success(let output): result = output
            case .failure(let failure): problem = failure.message
            }
        }
    }
}
