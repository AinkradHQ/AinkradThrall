import AinkradAppKit
import SwiftUI

/// Thrall's own engine, in the popover under the engine chip: mockup screens
/// 3, 4 and 5 (`Designs/thrall-engine/`). One view, switched on the phase, so
/// every state lives in the same place the user opened.
struct ThrallEnginePanel: View {
    @ObservedObject var engine: ThrallOwnEngineModel
    /// What uninstall would delete, counted when the user asks for it.
    let countContents: () async -> ThrallEngineContents?

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradSkin) private var skin
    @State private var confirmingStop = false
    @State private var uninstallContents: ThrallEngineContents?
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.md) {
            header
            content
            if let error = engine.actionError {
                AinkradBadge(text: error, status: .danger)
            }
        }
        .frame(width: skin.size.s56 * 7, alignment: .leading)
        .ainkradConfirmDialog(
            isPresented: $confirmingUninstall,
            title: "Uninstall Thrall's engine?",
            message: ThrallConfirmations.uninstallEngine(uninstallContents),
            confirmTitle: ThrallConfirmations.uninstallEngineButton(uninstallContents),
            isDestructive: true,
            onConfirm: { engine.uninstall() })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AinkradSpacing.sm) {
            Circle().fill(dotColor).frame(width: skin.size.s6, height: skin.size.s6)
            Text(title)
                .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold")))
            if let badge {
                AinkradBadge(text: badge.text, status: badge.status)
            }
            Spacer(minLength: 0)
            if case .running(let since?) = engine.phase {
                Text("up " + Self.uptime(since: since))
                    .font(skin.font(AinkradFontToken(sizeKey: "t10", monospacedDigits: true)))
                    .foregroundStyle(skin.color(skin.text.faint))
            }
        }
    }

    private var title: String {
        if case .installing = engine.phase { return "Installing Thrall's engine" }
        return "Thrall's engine"
    }

    private var badge: (text: String, status: AinkradStatus)? {
        switch engine.phase {
        case .running: return ("Running", .success)
        case .stopped: return ("Stopped", .neutral)
        case .starting: return ("Starting", .neutral)
        case .stopping: return ("Stopping", .neutral)
        case .restarting(let seconds?): return ("Restarting in \(seconds) s", .warning)
        case .restarting: return ("Restarting", .warning)
        case .failed: return ("Cannot start", .danger)
        case .installFailed: return ("Install failed", .danger)
        case .unsupported, .notInstalled, .installing: return nil
        }
    }

    private var dotColor: Color {
        ThrallEngineDot.color(for: engine.phase, theme: theme, skin: skin)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch engine.phase {
        case .unsupported:
            AinkradCaption("Thrall's engine needs an Apple silicon Mac.")
        case .notInstalled:
            AinkradCaption(
                "Run containers without another app: a small Linux VM on this Mac, with Docker inside. "
                    + "116 MB download. It keeps running after you quit Ainkrad, and lives in ~/.thrall.")
            AinkradButton(title: "Install Thrall's engine", style: .primary) { engine.install() }
        case .installFailed(let reason):
            AinkradCaption(reason)
            AinkradButton(title: "Try again", style: .primary) { engine.install() }
        case .installing(let step):
            installing(step)
        case .stopped:
            AinkradCaption("Installed, not running. Containers and volumes are kept on its disk.")
            facts(running: false)
            actions {
                AinkradButton(title: "Start", style: .primary, isLoading: engine.isBusy) { engine.start() }
            }
        case .starting, .stopping:
            AinkradCaption(
                engine.phase == .starting
                    ? "Booting the VM, then waiting for Docker to answer."
                    : "Shutting the VM down cleanly.")
            consoleTail
        case .restarting:
            AinkradCaption("The VM stopped unexpectedly. Each retry waits twice as long, up to a minute.")
            actions {
                AinkradButton(title: "Restart now", style: .secondary, isLoading: engine.isBusy) { engine.restart() }
                AinkradButton(title: "Stop", style: .secondary) { engine.stop() }
            }
        case .failed(let reason):
            AinkradCaption(reason)
            actions {
                // Re-running the install is the one fix that works: it
                // restores whatever image file the helper found missing.
                AinkradButton(title: "Repair", style: .primary) { engine.install() }
            }
        case .running:
            AinkradCaption("Docker in a Linux VM · context “\(ThrallOwnEngine.contextName)”")
            facts(running: true)
            ports
            actions {
                AinkradButton(title: "Stop", style: .secondary, isLoading: engine.isBusy) { confirmingStop = true }
                AinkradButton(title: "Restart", style: .secondary) { engine.restart() }
            }
            .ainkradConfirmDialog(
                isPresented: $confirmingStop,
                title: "Stop Thrall's engine?",
                message: "Every container on it stops. Containers and volumes are kept on its disk.",
                confirmTitle: "Stop",
                isDestructive: false,
                onConfirm: { engine.stop() })
        }
    }

    private func installing(_ step: ThrallEngineInstaller.Step) -> some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradCaption("This takes about two minutes on a fast connection. You can keep using Thrall.")
            ForEach(ThrallEngineInstallSteps.rows(for: step), id: \.title) { row in
                HStack(spacing: AinkradSpacing.sm) {
                    Image(systemName: row.state.symbol)
                        .foregroundStyle(row.state == .pending ? skin.color(skin.text.faint) : theme.accentPrimary)
                        .frame(width: skin.size.s16)
                    VStack(alignment: .leading, spacing: skin.size.s2) {
                        Text(row.title)
                            .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                            .foregroundStyle(
                                row.state == .pending ? skin.color(skin.text.faint) : theme.foreground)
                        if let fraction = row.fraction {
                            AinkradStatusBar(value: fraction)
                        }
                    }
                }
            }
            actions {
                AinkradButton(title: "Cancel", style: .secondary) { engine.cancelInstall() }
            }
        }
    }

    private func facts(running: Bool) -> some View {
        let config = ThrallOwnEngine.config(engine.paths)
        return VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            if running {
                fact("CPUs", "\(config.cpuCount)")
                fact("Memory", "\(config.memoryGiB) GB")
            }
            fact("Disk", Self.disk(used: engine.diskUsedBytes, size: engine.diskSizeBytes))
            if running {
                fact("Socket", Self.tildePath(engine.paths.dockerSocket.path))
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AinkradSpacing.md) {
            Text(label)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.muted))
                .frame(width: skin.size.s56 * 1.6, alignment: .leading)
            Text(value)
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var ports: some View {
        let status = engine.status
        let forwarded = status?.forwardedPorts ?? []
        let conflicted = status?.conflictedPorts ?? []
        if !forwarded.isEmpty || !conflicted.isEmpty {
            VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
                Text("Ports on localhost")
                    .font(skin.font(AinkradFontToken(sizeKey: "t10", weight: "semibold")))
                    .foregroundStyle(skin.color(skin.text.muted))
                ForEach(forwarded, id: \.self) { port in
                    portRow(port, badge: "forwarded", status: .success)
                }
                // The full sentence lives in the toast that announced it; the
                // row only needs to say the port is not reaching the guest.
                ForEach(conflicted, id: \.self) { port in
                    portRow(port, badge: "in use on this Mac", status: .warning)
                }
            }
        }
    }

    /// Same compact row as the facts above, so the panel reads as one list.
    private func portRow(_ port: Int, badge: String, status: AinkradStatus) -> some View {
        HStack(spacing: AinkradSpacing.md) {
            // Verbatim: an interpolated Int in a localized key prints "3,000".
            Text(verbatim: "localhost:\(port)")
                .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                .textSelection(.enabled)
            Spacer(minLength: 0)
            AinkradBadge(text: badge, status: status)
        }
    }

    @ViewBuilder
    private var consoleTail: some View {
        if !engine.consoleTail.isEmpty {
            Text(engine.consoleTail.joined(separator: "\n"))
                .font(skin.font(AinkradFontToken(sizeKey: "t10", monospacedDigits: true)))
                .foregroundStyle(skin.color(skin.text.muted))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
        HStack(spacing: AinkradSpacing.sm) {
            buttons()
            Spacer(minLength: 0)
            if engine.phase.isInstalled {
                AinkradButton(title: "Uninstall…", style: .ghost) {
                    Task {
                        uninstallContents = await countContents()
                        confirmingUninstall = true
                    }
                }
            }
        }
    }

    // MARK: - Formatting

    static func disk(used: Int64?, size: Int64?) -> String {
        guard let used else { return "—" }
        let usedText = ThrallReclaimPlan.humanBytes(used) + " used"
        return size.map { usedText + " of " + ThrallReclaimPlan.humanBytes($0) } ?? usedText
    }

    static func tildePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func uptime(since: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since)) / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// The installing panel's rows: the installer's real steps, in order.
enum ThrallEngineInstallSteps {
    enum RowState: Equatable {
        case done, active, pending

        var symbol: String {
            switch self {
            case .done: return "checkmark"
            case .active: return "smallcircle.filled.circle"
            case .pending: return "circle"
            }
        }
    }

    struct Row: Equatable {
        let title: String
        let state: RowState
        let fraction: Double?
    }

    static func rows(for step: ThrallEngineInstaller.Step) -> [Row] {
        let titles = [
            "Downloading the engine image", "Downloading docker-compose", "Verifying both downloads",
            "Starting the engine",
        ]
        let (index, fraction): (Int, Double?) = {
            switch step {
            case .downloadingImage(let fraction): return (0, fraction)
            case .downloadingCompose(let fraction): return (1, fraction)
            case .verifying: return (2, nil)
            case .starting: return (3, nil)
            }
        }()
        return titles.enumerated().map { offset, title in
            Row(
                title: title,
                state: offset < index ? .done : offset == index ? .active : .pending,
                fraction: offset == index ? fraction : nil)
        }
    }
}

/// One colour rule for the engine's dot, in the chip and in the panel.
enum ThrallEngineDot {
    @MainActor
    static func color(for phase: ThrallOwnEngineModel.Phase, theme: HostThemeTokens, skin: AinkradSkin) -> Color {
        switch phase {
        case .running: return theme.accentPrimary
        case .starting, .stopping, .installing: return theme.accentSecondary
        case .restarting: return skin.color(skin.palette.warning)
        case .failed, .installFailed: return skin.color(skin.palette.danger)
        case .stopped, .notInstalled, .unsupported: return theme.foreground.opacity(skin.opacity.o35)
        }
    }
}

/// What uninstalling would delete, counted from the engine itself.
struct ThrallEngineContents: Equatable, Sendable {
    var containers: Int
    var images: Int
    var volumeNames: [String]
}
