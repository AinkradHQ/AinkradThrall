import SwiftUI
import AinkradAppKit

/// Thrall — a container manager framed around the **stack** (a compose project)
/// rather than the container.
///
/// The engine is never ours: Thrall drives whatever is already running
/// (OrbStack, Docker Desktop, Podman) through the Docker Engine API over an
/// AF_UNIX socket, and through `docker compose` for the orchestration verbs the
/// API does not expose.
public struct ThrallApp: AinkradApp, AinkradAppTeardown {
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

    /// **Mandatory here, and heavier than for a plugin that only reads files.**
    /// An uncancelled `NWConnection` keeps a socket *and* a dispatch source
    /// alive, so without this Thrall would go on waking the CPU after its
    /// window closed.
    public static func teardown(instance: PluginInstanceID) {
        ThrallRuntime.teardown(instance: instance)
    }

    /// The window's own fill, so the title bar reads as continuous with the
    /// body rather than as a separate bar above it.
    public static func chromeFill(host: HostServices) -> Color? {
        host.theme.tokens.background
    }
}
