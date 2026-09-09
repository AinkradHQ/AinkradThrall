import Foundation
import AinkradAppKit

/// Thrall's own settings. Presentation (overlay vs pane) is **not** here — it
/// lives in the host, through `HostServices.presentation`, so the host can act
/// on it before any of Thrall's code runs.
public struct ThrallSettings: Codable, Equatable, Sendable {
    /// Show the pseudo-stack holding containers with no compose project.
    /// Defaults on: two containers here have no labels at all, and an
    /// invisible running container is the worst thing a container manager can
    /// do.
    public var showUnmanaged: Bool
    /// Confirm before taking a stack down. On by default because `down`
    /// destroys state; `restart` and `up` never confirm.
    public var confirmBeforeDown: Bool
    /// Seconds between reconcile polls. The floor exists because `/events` can
    /// die silently on an engine restart, after which a purely event-driven UI
    /// freezes on stale state.
    public var pollSeconds: Int

    public init(showUnmanaged: Bool = true,
                confirmBeforeDown: Bool = true,
                pollSeconds: Int = 10) {
        self.showUnmanaged = showUnmanaged
        self.confirmBeforeDown = confirmBeforeDown
        self.pollSeconds = pollSeconds
    }

    public static let `default` = ThrallSettings()
    /// Clamped, so a hand-edited document cannot busy-loop the engine.
    public var effectivePollSeconds: Int { min(max(pollSeconds, 2), 300) }
}

/// The one observable settings store per plugin instance, shared by the root
/// view, the settings pane and `chromeFill` — the trio that must agree, and
/// that used to be three separate reads in every plugin.
@MainActor
public final class ThrallSettingsStore: ObservableObject {
    private static let documentKey = "thrall.settings.v1"
    private let documents: any PluginDocumentStore

    @Published public var settings: ThrallSettings {
        didSet { persist() }
    }

    public init(documents: any PluginDocumentStore) {
        self.documents = documents
        if let data = documents.data(forKey: Self.documentKey),
           let decoded = try? JSONDecoder().decode(ThrallSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    private func persist() {
        // A settings write that cannot be encoded is dropped rather than
        // thrown: losing a preference is better than failing the UI action
        // that changed it.
        guard let data = try? JSONEncoder().encode(settings) else { return }
        documents.setData(data, forKey: Self.documentKey)
    }
}
