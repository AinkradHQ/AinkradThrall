import AinkradAppKit
import SwiftUI

/// Thrall's settings as DECLARED fields, so the host draws them in the shared
/// settings style — and puts its Appearance tab (Open as, Open in, Blur) first.
/// `ThrallSettingsView` stays as the page for hosts that predate this.
@MainActor
enum ThrallSettingsCatalog {
    static func page(store: ThrallSettingsStore) -> SettingsPage {
        let group = SettingsPath([ThrallApp.id, "containers"])
        let defaults = ThrallSettings()
        return SettingsPage(
            path: SettingsPath([ThrallApp.id]), title: ThrallApp.displayName, icon: ThrallApp.icon,
            group: .installedApps, order: 0,
            groups: [
                SettingsGroup(
                    path: group,
                    title: "Containers",
                    footerNote: "Thrall drives the container engine you already run — it never owns one.",
                    fields: [
                        SettingsField(
                            path: group.appending("unmanaged"),
                            label: "Unmanaged containers",
                            help: "Containers with no compose project get their own row. Two on this "
                                + "machine have no labels at all, and a running container you cannot "
                                + "see is worse than a crowded list.",
                            keywords: ["unmanaged", "compose", "labels", "containers"],
                            kind: .toggle(
                                Binding(
                                    get: { store.settings.showUnmanaged },
                                    set: { store.settings.showUnmanaged = $0 })),
                            defaultDescription: defaults.showUnmanaged ? "On" : "Off",
                            isModified: { store.settings.showUnmanaged != defaults.showUnmanaged },
                            reset: { store.settings.showUnmanaged = defaults.showUnmanaged }),
                        SettingsField(
                            path: group.appending("confirm-down"),
                            label: "Confirm before Down",
                            help: "Down destroys state. Restart and Up never confirm — gating an action "
                                + "that fixes a broken service is what makes people stop using the tool.",
                            keywords: ["confirm", "down", "destroy", "safety"],
                            kind: .toggle(
                                Binding(
                                    get: { store.settings.confirmBeforeDown },
                                    set: { store.settings.confirmBeforeDown = $0 })),
                            defaultDescription: defaults.confirmBeforeDown ? "On" : "Off",
                            isModified: { store.settings.confirmBeforeDown != defaults.confirmBeforeDown },
                            reset: { store.settings.confirmBeforeDown = defaults.confirmBeforeDown }),
                    ])
            ],
            appID: ThrallApp.id)
    }
}
