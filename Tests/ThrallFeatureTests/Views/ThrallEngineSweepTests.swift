import AinkradAppKit
import AppKit
import SwiftUI
import Testing

@testable import ThrallFeature

/// E4's screens, shot under Neon and Liquid Glass for review against
/// `Designs/thrall-engine/`. A tool, not a check, like the chrome sweep: it
/// runs only with AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR set, and draws real
/// views in a desktop-level panel, so no input is ever sent to a host.
@Suite("Thrall engine sweep")
@MainActor
struct ThrallEngineSweepTests {
    @Test("shoot the engine panel in every phase, the offer and the settings")
    func shoot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["AINKRAD_SWEEP_DIR"], let themes = env["AINKRAD_THEMES_DIR"] else {
            print("SKIPPED: set AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR — no engine sweep")
            return
        }
        let glass = try NativeGlassSweepTests.glassSkin(themes: URL(fileURLWithPath: themes))
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let since = Date().addingTimeInterval(-(3 * 3600 + 12 * 60))
        let gib: Int64 = 1 << 30
        let boot = [
            " * Mounting Thrall data disk ... [ ok ]", " * Mounting /Users/ahmedmelhalaby ... [ ok ]",
            " *   eth0 ...udhcpc: lease of 192.168.64.3 obtained", " * Starting Docker Daemon ... [ ok ]",
            " * Starting thrall-socket ... [ ok ]",
        ]
        let panels: [(String, (ThrallOwnEngineModel) -> Void)] = [
            ("1-not-installed", { $0.preview(phase: .notInstalled) }),
            ("3-installing", { $0.preview(phase: .installing(.downloadingImage(fraction: 0.62))) }),
            (
                "4-running",
                {
                    $0.preview(
                        phase: .running(since: since),
                        status: ThrallEngineStatus(
                            phase: .running, runningSince: since, forwardedPorts: [3000, 8080], conflictedPorts: [5432]),
                        diskUsed: 3 * gib + gib / 10, diskSize: 64 * gib)
                }
            ),
            ("5a-stopped", { $0.preview(phase: .stopped, diskUsed: 3 * gib + gib / 10, diskSize: 64 * gib) }),
            ("5b-starting", { $0.preview(phase: .starting, console: boot) }),
            ("5c-restarting", { $0.preview(phase: .restarting(retryIn: 8)) }),
            (
                "5d-failed",
                {
                    $0.preview(
                        phase: .failed(
                            "The engine image is incomplete: ~/.thrall/vm/rootfs.img does not exist. "
                                + "Run scripts/build-engine-image.sh."))
                }
            ),
            (
                "2b-install-failed",
                { $0.preview(phase: .installFailed("The download failed: The network connection was lost.")) }
            ),
        ]
        for (theme, skin) in [("neon", AinkradSkin.standard), ("glass", glass)] {
            for (name, configure) in panels {
                let engine = Self.engine()
                configure(engine)
                try shoot(
                    ThrallEnginePanel(engine: engine, countContents: { nil }).padding(20),
                    skin: skin, size: CGSize(width: 460, height: 420), name: "panel-\(name)-\(theme)", out: out)
            }
            let offerEngine = Self.engine()
            offerEngine.preview(phase: .notInstalled)
            try shoot(
                ThrallEngineOffer(engine: offerEngine, dismiss: {}), skin: skin,
                size: CGSize(width: 900, height: 520), name: "offer-\(theme)", out: out)
            let page = ThrallSettingsCatalog.page(
                store: ThrallSettingsStore(documents: SweepDocs()), engine: Self.engine())
            try shoot(
                SettingsPageView(page: page).padding(20), skin: skin,
                size: CGSize(width: 760, height: 640), name: "settings-\(theme)", out: out)
            try shoot(
                SettingsPageView(page: page, highlightedPath: SettingsPath([ThrallApp.id, "engine", "cpus"]))
                    .padding(20), skin: skin,
                size: CGSize(width: 760, height: 640), name: "settings-engine-\(theme)", out: out)
        }
    }

    private func shoot(_ view: some View, skin: AinkradSkin, size: CGSize, name: String, out: String) throws {
        try LiveGlassCapture.shoot(
            view
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(skin.color(skin.palette.background))
                .ainkradSkin(skin)
                .environment(\.colorScheme, .dark),
            size: size,
            to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
    }

    private static func engine() -> ThrallOwnEngineModel {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        let paths = ThrallOwnEngine.Paths(
            root: home.appendingPathComponent(".thrall"),
            launchAgents: home.appendingPathComponent("Library/LaunchAgents"))
        return ThrallOwnEngineModel(installer: ThrallEngineInstaller(paths: paths, helperSource: nil))
    }
}

private final class SweepDocs: PluginDocumentStore {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}
