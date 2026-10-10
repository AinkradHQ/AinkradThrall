import AinkradAppKit
import AppKit
import SwiftUI
import Testing

@testable import ThrallFeature

/// Glass Native E5: Thrall's own chrome under Neon and Liquid Glass, written as
/// `<dir>/<name>-neon.png` / `-glass.png`. A tool, not a check: it runs only with
/// AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR (the catalog's `themes/`) set.
/// Live window captures — off-screen `cacheDisplay` cannot draw Liquid Glass.
@Suite("Thrall native glass sweep")
@MainActor
struct NativeGlassSweepTests {
    @Test("shoot Thrall's chrome under Neon and Glass")
    func shoot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["AINKRAD_SWEEP_DIR"], let themes = env["AINKRAD_THEMES_DIR"] else {
            print("SKIPPED: set AINKRAD_SWEEP_DIR and AINKRAD_THEMES_DIR — no native Glass sweep")
            return
        }
        let glass = try Self.glassSkin(themes: URL(fileURLWithPath: themes))
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let fixtures: [(String, AnyView)] = [
            ("pullDown-engine", AnyView(
                ThrallPullDownLabel {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Docker Desktop").font(.system(size: 11, weight: .medium))
                    Text("API 1.47").font(.system(size: 10)).foregroundStyle(.secondary)
                })),
            ("pullDown-engineMenu", AnyView(
                AinkradMenuButton(items: [AinkradMenuItem(title: "Docker Desktop") {}]) {
                    ThrallPullDownLabel {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("Docker Desktop").font(.system(size: 11, weight: .medium))
                    }
                })),
            ("pullDown-menu", AnyView(
                AinkradMenuButton(items: [AinkradMenuItem(title: "Docker Desktop") {}]) {
                    ThrallPullDownLabel { Text("All containers").font(.system(size: 11)) }
                })),
        ]
        for (name, view) in fixtures {
            for (theme, skin) in [("neon", AinkradSkin.standard), ("glass", glass)] {
                try LiveGlassCapture.shoot(
                    view.padding(16)
                        .frame(width: 400, height: 120)
                        .background(skin.color(skin.palette.background))
                        .ainkradSkin(skin)
                        .environment(\.colorScheme, .dark),
                    size: CGSize(width: 400, height: 120),
                    to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(theme).png"))
            }
        }
    }

    /// `glass-dark.theme` on the standard skin, coloured by `glass-dark.scheme`,
    /// composed the way the host's `ThemeCatalog.compose` does.
    static func glassSkin(themes: URL) throws -> AinkradSkin {
        let dir = themes.appendingPathComponent("glass")
        let base = try JSONEncoder().encode(AinkradSkin.standard)
        let theme = try Data(contentsOf: dir.appendingPathComponent("glass-dark.theme"))
        let variant = try #require(ainkradLoadThemes([base, theme]).themes["glass.dark"])
        var scheme = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("glass-dark.scheme")))
                as? [String: Any])
        scheme.removeValue(forKey: "appearance")
        scheme.removeValue(forKey: "host")
        scheme["base"] = "glass.dark"
        return try AinkradThemeFile(
            decoding: JSONSerialization.data(withJSONObject: scheme), bases: ["glass.dark": variant]
        ).skin
    }
}

/// A real window at desktop level (behind every window, no focus taken) that
/// claims key appearance so glass tints render; `screencapture -l` grabs it.
@MainActor
enum LiveGlassCapture {
    private final class KeyAppearancePanel: NSPanel {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { false }
        @objc var hasKeyAppearance: Bool { true }
        @objc var hasMainAppearance: Bool { true }
        @objc var _hasActiveAppearance: Bool { true }
        @objc var _hasActiveAppearanceIgnoringKeyFocus: Bool { true }
    }

    static func shoot(_ view: some View, size: CGSize, to url: URL) throws {
        let panel = KeyAppearancePanel(
            contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = false
        panel.contentView = NSHostingView(
            rootView: view.environment(\.ainkradMotionBudget, .frozen).environment(\.controlActiveState, .key))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), url.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0 { return }
        // The test runner may lack the Screen Recording grant: hand the window
        // to `.build/capture-broker.sh <dir>`, which runs `screencapture` for it.
        let requests = url.deletingLastPathComponent().appendingPathComponent(".requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try "\(panel.windowNumber) \(url.path)".write(
            to: requests.appendingPathComponent(UUID().uuidString + ".req"), atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "no capture for \(url.lastPathComponent)")
    }
}
