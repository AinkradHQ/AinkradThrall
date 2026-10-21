import Foundation
import Testing

@testable import ThrallFeature

/// The real thing: downloads the published image and compose, installs the
/// launchd job, boots the VM and asks its engine for its version.
///
/// Opt-in only. It changes the machine (`~/.thrall`, a LaunchAgent) and
/// downloads about 180 MB, so it runs only when asked:
///
///     TEST_RUNNER_THRALL_LIVE_INSTALL=1 \
///     TEST_RUNNER_THRALL_ENGINE_HELPER=$PWD/build/Build/Products/Debug/thrall-engine \
///     xcodebuild test ... -only-testing:ThrallFeatureTests/ThrallEngineInstallLiveTests
@Suite(
    "ThrallEngineInstaller, live",
    .enabled(if: ProcessInfo.processInfo.environment["THRALL_LIVE_INSTALL"] == "1"))
struct ThrallEngineInstallLiveTests {
    @Test("install boots the engine and its socket answers")
    func installAndBoot() async throws {
        let helper = try #require(ProcessInfo.processInfo.environment["THRALL_ENGINE_HELPER"])
        let installer = ThrallEngineInstaller(helperSource: URL(fileURLWithPath: helper))
        try await installer.install()
        #expect(installer.isLoaded())

        let client = try ThrallEngineClient(endpoint: .unixSocket(path: installer.paths.dockerSocket.path))
        var version: ThrallEngineVersion?
        for _ in 0..<60 where version == nil {
            version = try? await client.version()
            if version == nil { try await Task.sleep(for: .seconds(1)) }
        }
        #expect(version != nil)
    }
}
