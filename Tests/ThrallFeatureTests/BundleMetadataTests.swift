import Foundation
import Testing
import AinkradAppKit

/// Guards the bundle metadata that the host reads but no build step verifies.
///
/// `AinkradPresentation` is the one that matters: it is read *outside*
/// `PluginBundleMetadata.parse`, has a silent default of `pane`, and is a
/// single line in a plist. Drop it and Thrall quietly stops opening as an
/// overlay with nothing failing anywhere.
@Suite("Bundle metadata")
struct BundleMetadataTests {
    /// The repo's source Info.plist, located relative to this test file so the
    /// test does not depend on where the bundle happens to be built.
    private static func sourceInfoPlist() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()   // ThrallFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let plist = repoRoot
            .appendingPathComponent("Sources/ThrallPlugin/Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization
            .propertyList(from: data, options: [], format: nil)
        return try #require(parsed as? [String: Any])
    }

    @Test("Thrall declares itself an overlay, like Leyline")
    func declaresOverlayPresentation() throws {
        let info = try Self.sourceInfoPlist()
        let raw = try #require(info["AinkradPresentation"] as? String)
        #expect(PluginPresentation(rawValue: raw) == .overlay)
    }

    @Test("the app id matches the one the code declares")
    func appIDMatchesCode() throws {
        let info = try Self.sourceInfoPlist()
        #expect(info["AinkradAppID"] as? String == "thrall")
    }

    @Test("principal class matches the @objc name the entry point exports")
    func principalClassMatches() throws {
        let info = try Self.sourceInfoPlist()
        #expect(info["NSPrincipalClass"] as? String == "ThrallEntryPoint")
    }

    @Test("CFBundleExecutable is set — the host renames the bundle and needs it")
    func executableIsDeclared() throws {
        let info = try Self.sourceInfoPlist()
        let exe = try #require(info["CFBundleExecutable"] as? String)
        #expect(!exe.isEmpty)
    }
}
