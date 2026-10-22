import AinkradAppKit
import SwiftUI

/// Thrall's settings as DECLARED fields, so the host draws them in the shared
/// settings style — and puts its Appearance tab (Open as, Open in, Blur) first.
@MainActor
enum ThrallSettingsCatalog {
    static func page(store: ThrallSettingsStore, engine: ThrallOwnEngineModel) -> SettingsPage {
        let group = SettingsPath([ThrallApp.id, "containers"])
        let defaults = ThrallSettings()
        return SettingsPage(
            path: SettingsPath([ThrallApp.id]), title: ThrallApp.displayName, icon: ThrallApp.icon,
            group: .installedApps, order: 0,
            groups: [
                SettingsGroup(
                    path: group,
                    title: "Containers",
                    footerNote:
                        "Thrall drives whichever engine you select. It can also run its own: see Thrall's engine.",
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
                    ]),
                engineGroup(engine),
            ],
            appID: ThrallApp.id)
    }

    /// Thrall's own engine (mockup screen 6). Each value lives in the file the
    /// engine reads, `engine.json` or the LaunchAgent plist, so there is no
    /// second copy in Thrall's settings document to drift from it. Uninstall
    /// is in the engine panel, where it can confirm with what it deletes.
    private static func engineGroup(_ engine: ThrallOwnEngineModel) -> SettingsGroup {
        let group = SettingsPath([ThrallApp.id, "engine"])
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let defaults = ThrallOwnEngine.config(engine.paths)
        func config() -> ThrallEngineConfig { ThrallOwnEngine.config(engine.paths) }
        return SettingsGroup(
            path: group,
            title: "Thrall's engine",
            footerNote: "CPUs, memory and disk size apply the next time the engine starts. Changing them "
                + "never restarts a running engine.",
            fields: [
                SettingsField(
                    path: group.appending("cpus"),
                    label: "CPUs",
                    help: "How many of this Mac's \(cores) cores the engine's VM may use.",
                    keywords: ["cpu", "cores", "engine", "vm"],
                    kind: .select(
                        options: (1...cores).map { SettingsOption(id: "\($0)", title: "\($0) of \(cores)") },
                        selection: Binding(
                            get: { "\(config().cpuCount)" },
                            set: { value in
                                guard let count = Int(value) else { return }
                                var next = config()
                                next.cpuCount = count
                                engine.writeConfig(next)
                            })),
                    defaultDescription: "\(defaults.cpuCount)",
                    isModified: { false },
                    reset: {}),
                SettingsField(
                    path: group.appending("memory"),
                    label: "Memory",
                    help: "Memory the engine's VM may use. The VM returns memory it is not using.",
                    keywords: ["memory", "ram", "engine", "vm"],
                    kind: .select(
                        options: ThrallEngineConfig.memoryChoices.map {
                            SettingsOption(id: "\($0)", title: "\($0) GB")
                        },
                        selection: Binding(
                            get: { "\(config().memoryGiB)" },
                            set: { value in
                                guard let gib = Int(value) else { return }
                                var next = config()
                                next.memoryGiB = gib
                                engine.writeConfig(next)
                            })),
                    defaultDescription: "4 GB",
                    isModified: { false },
                    reset: {}),
                SettingsField(
                    path: group.appending("disk"),
                    label: "Disk size",
                    help: "The most the engine's disk can hold: images, containers and volumes. It can "
                        + "only grow, because shrinking would cut off the volumes stored at its end. "
                        + "It takes space on this Mac only as it fills.",
                    keywords: ["disk", "storage", "size", "engine", "volumes"],
                    kind: .select(
                        options: diskOptions(engine),
                        selection: Binding(
                            get: { "\(config().diskGiB)" },
                            set: { value in
                                guard let gib = Int(value), gib >= config().diskGiB else { return }
                                var next = config()
                                next.diskGiB = gib
                                engine.writeConfig(next)
                            })),
                    defaultDescription: "\(ThrallEngineConfig.defaultDiskGiB) GB",
                    isModified: { false },
                    reset: {}),
                SettingsField(
                    path: group.appending("login"),
                    label: "Start at login",
                    help: "Start Thrall's engine when you log in, before Ainkrad is opened. Off keeps it "
                        + "installed and startable from the engine chip.",
                    keywords: ["login", "launch", "startup", "engine"],
                    kind: .toggle(
                        Binding(
                            get: { ThrallOwnEngine.startsAtLogin(engine.paths) },
                            set: { engine.setStartsAtLogin($0) })),
                    defaultDescription: "On",
                    isModified: { !ThrallOwnEngine.startsAtLogin(engine.paths) },
                    reset: { engine.setStartsAtLogin(true) }),
            ])
    }

    /// Sizes at or above both the chosen size and the disk as it exists:
    /// never an option that would ask for a shrink.
    private static func diskOptions(_ engine: ThrallOwnEngineModel) -> [SettingsOption] {
        let existing =
            (try? engine.paths.dataDisk.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
                Int(($0 + (1 << 30) - 1) >> 30)
            } ?? 0
        let floor = max(existing, ThrallOwnEngine.config(engine.paths).diskGiB)
        var sizes = ThrallEngineConfig.diskChoices.filter { $0 >= floor }
        if !sizes.contains(floor) { sizes.insert(floor, at: 0) }
        return sizes.map { SettingsOption(id: "\($0)", title: "\($0) GB") }
    }
}
