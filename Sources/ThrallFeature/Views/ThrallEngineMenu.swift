import AinkradAppKit
import Foundation

/// The engine chip's menu: every context with what Thrall knows of its state,
/// then the verbs on Thrall's own engine (mockup screen 1).
///
/// The kit's menu has no trailing detail column, so the state rides in the
/// title after an em dash: the same pattern "— unavailable" already used.
enum ThrallEngineMenu {
    @MainActor
    static func items(
        contexts: [ThrallEngineContext],
        activeContext: ThrallEngineContext?,
        activeState: ThrallViewModel.LoadState,
        ownEngine: ThrallOwnEngineModel.Phase,
        select: @escaping (ThrallEngineContext) -> Void,
        start: @escaping () -> Void,
        stop: @escaping () -> Void,
        manage: @escaping () -> Void
    ) -> [AinkradMenuItem] {
        var items = contexts.map { context in
            AinkradMenuItem(
                title: title(for: context, active: activeContext, activeState: activeState, ownEngine: ownEngine),
                systemName: context.isSupported ? "bolt.horizontal" : "bolt.horizontal.circle"
            ) { select(context) }
        }
        var engine: [AinkradMenuItem] = []
        switch ownEngine {
        case .unsupported:
            break
        case .notInstalled, .installFailed, .installing:
            engine.append(
                AinkradMenuItem(title: "Run containers without another app…", systemName: "shippingbox") {
                    manage()
                })
        case .stopped:
            engine.append(AinkradMenuItem(title: "Start Thrall's engine", systemName: "play.fill") { start() })
        case .running, .restarting:
            engine.append(AinkradMenuItem(title: "Stop Thrall's engine", systemName: "stop.fill") { stop() })
        case .starting, .stopping, .failed:
            break
        }
        if ownEngine.isInstalled {
            engine.append(AinkradMenuItem(title: "Manage Thrall's engine…", systemName: "gearshape") { manage() })
        }
        if let first = engine.first {
            engine[0] = first.startingGroup()
        }
        items += engine
        return items
    }

    /// Only states Thrall actually knows: its own engine's phase, and the
    /// active context's last read. Another context is never claimed to be
    /// running from a socket file merely existing.
    static func title(
        for context: ThrallEngineContext,
        active: ThrallEngineContext?,
        activeState: ThrallViewModel.LoadState,
        ownEngine: ThrallOwnEngineModel.Phase
    ) -> String {
        guard context.isSupported else { return "\(context.name) — unavailable" }
        if context.name == ThrallOwnEngine.contextName {
            return "\(context.name) — \(ownEngineWord(ownEngine))"
        }
        if context.name == active?.name {
            switch activeState {
            case .loaded: return "\(context.name) — running"
            case .failed: return "\(context.name) — not running"
            case .idle, .loading: return context.name
            }
        }
        if case .unixSocket(let path) = context.endpoint, !FileManager.default.fileExists(atPath: path) {
            return "\(context.name) — not running"
        }
        return context.name
    }

    static func ownEngineWord(_ phase: ThrallOwnEngineModel.Phase) -> String {
        switch phase {
        case .running: return "running"
        case .starting: return "starting"
        case .stopping: return "stopping"
        case .restarting: return "restarting"
        case .stopped: return "stopped"
        case .failed: return "cannot start"
        case .installing: return "installing"
        case .notInstalled, .installFailed, .unsupported: return "not installed"
        }
    }
}
