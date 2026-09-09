import SwiftUI
import AinkradAppKit

/// Thrall — a container manager framed around the **stack** (a compose project)
/// rather than the container.
///
/// The engine is never ours: Thrall drives whatever is already running
/// (OrbStack, Docker Desktop, Podman) through the Docker Engine API over an
/// AF_UNIX socket, and through `docker compose` for the orchestration verbs the
/// API does not expose.
public struct ThrallApp: AinkradApp, AinkradAppTeardown, AinkradAppMCP {
    public static let id = "thrall"
    public static let displayName = "Thrall"
    public static let icon = "cube.transparent"

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(ThrallShell(host: host))
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(
            ThrallSettingsView(presentation: host.presentation,
                               store: ThrallRuntime.settingsStore(for: host))
                .ainkradHostTheme(host.theme)
        )
    }

    /// **MCP is the only front door the assistant has.** No
    /// `AgentActionProvider` actions are registered: GitMage deleted its
    /// `git_op` action seam once MCP existed, and two seams onto the same
    /// capability means two places to forget a guard.
    public static func makeMCPServer(host: HostServices) -> MCPAppServer {
        ThrallRuntime.mcpServer(for: host)
    }

    /// **Mandatory here, and heavier than for a plugin that only reads files.**
    /// An uncancelled `NWConnection` keeps a socket *and* a dispatch source
    /// alive, so without this Thrall would go on waking the CPU after its
    /// window closed.
    public static func teardown(instance: PluginInstanceID) {
        // The host does not hand `teardown` a `HostServices`, so the
        // context token is dropped from the registry here and the host's own
        // registration goes stale rather than leaking a live source — the
        // bridge it closes over is released, so its snapshot returns nil.
        ThrallRuntime.teardown(instance: instance)
    }

    /// The window's own fill, so the title bar reads as continuous with the
    /// body rather than as a separate bar above it.
    public static func chromeFill(host: HostServices) -> Color? {
        host.theme.tokens.background
    }
}
