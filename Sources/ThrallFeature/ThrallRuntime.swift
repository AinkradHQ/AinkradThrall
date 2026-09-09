import Foundation
import AinkradAppKit

/// Bridges Thrall's static `AinkradApp` entry points to one shared settings
/// store and one view model per plugin instance, so the root view, the
/// settings pane and `chromeFill` all read the same state and restyle live.
///
/// Keyed by the **host-minted** `PluginInstanceID`, following
/// `GitMageRuntime`, which learned this the hard way: keying on
/// `ObjectIdentifier(host as AnyObject)` is the address of a box around a
/// non-class-bound existential, and the runtime may reuse it once freed — so a
/// new host could be handed the previous host's store, and nothing was ever
/// evicted.
@MainActor
enum ThrallRuntime {
    private static let stores = PluginInstanceStorage<ThrallSettingsStore>()
    private static let models = PluginInstanceStorage<ThrallViewModel>()
    private static var legacyIDs: [ObjectIdentifier: PluginInstanceID] = [:]

    /// The instance key for `host`.
    ///
    /// A host that implements `PluginInstanceIdentity` mints one. An older host
    /// does not, so we fall back to per-host object identity rather than to a
    /// single shared id — collapsing every legacy host onto one key would make
    /// two windows share a view model, which is a regression, not a fallback.
    static func instance(of host: HostServices) -> PluginInstanceID {
        if let identified = host as? PluginInstanceIdentity { return identified.instanceID }
        let key = ObjectIdentifier(host as AnyObject)
        if let existing = legacyIDs[key] { return existing }
        let minted = PluginInstanceID()
        legacyIDs[key] = minted
        return minted
    }

    static func settingsStore(for host: HostServices) -> ThrallSettingsStore {
        stores.value(for: instance(of: host)) { ThrallSettingsStore(documents: host.documents) }
    }

    static func viewModel(for host: HostServices) -> ThrallViewModel {
        models.value(for: instance(of: host)) {
            ThrallViewModel(host: host, settings: settingsStore(for: host))
        }
    }

    private static let bridges = PluginInstanceStorage<ThrallContextBridge>()
    private static let contextTokens = PluginInstanceStorage<PluginContextToken>()

    /// The per-instance context bridge, **registered with the host exactly
    /// once** and its token kept so teardown can remove it. GitMage's version
    /// of this was "never removed", which left a dead context source
    /// registered for every instance ever opened.
    static func contextBridge(for host: HostServices) -> ThrallContextBridge {
        let id = instance(of: host)
        var created: ThrallContextBridge?
        let bridge = bridges.value(for: id) {
            let made = ThrallContextBridge()
            created = made
            return made
        }
        if created != nil {
            contextTokens.value(for: id) { host.context.register { bridge.snapshot() } }
        }
        return bridge
    }

    private static let mcpServers = PluginInstanceStorage<MCPAppServer>()

    /// The per-instance MCP server, sharing the live view model so a tool
    /// drives the on-screen instance rather than a detached copy.
    static func mcpServer(for host: HostServices) -> MCPAppServer {
        let id = instance(of: host)
        return mcpServers.value(for: id) {
            let (server, failures) = ThrallMCPServer.make(
                appID: ThrallApp.id,
                model: { viewModel(for: host) })
            // A dropped tool is a silently missing capability — say so rather
            // than let the assistant simply never see it.
            if !failures.isEmpty {
                host.log.error("Thrall MCP: rejected — \(failures.joined(separator: ", "))")
            }
            return server
        }
    }

    /// Releases everything scoped to `instance`.
    ///
    /// **Heavier than a plugin that only reads files.** An uncancelled
    /// `NWConnection` keeps a socket *and* a dispatch source alive, so it would
    /// go on waking the CPU after Thrall's window closed. The view model's own
    /// `shutdown()` cancels its poll task and closes anything open; dropping it
    /// from the registry without that would leak both.
    static func teardown(instance: PluginInstanceID, host: HostServices? = nil) {
        if let token = contextTokens.remove(instance) { host?.context.remove(token) }
        bridges.remove(instance)
        stores.remove(instance)
        mcpServers.remove(instance)
        models.remove(instance)?.shutdown()
        legacyIDs = legacyIDs.filter { $0.value != instance }
    }
}
