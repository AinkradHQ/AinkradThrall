import Foundation

/// Thrall's own engine, as the plugin installs and controls it: the
/// `thrall-engine` helper under launchd, the guest image and a standalone
/// `docker-compose`, all under `~/.thrall`.
///
/// Every download is pinned to a SHA-256 **in this file**, not read from the
/// release: a release asset that was swapped fails verification instead of
/// running as a VM image or a binary.
enum ThrallOwnEngine {
    struct Artifact: Sendable, Equatable {
        let version: String
        let url: String
        let sha256: String
    }

    static let image = Artifact(
        version: "engine-image-v2",
        url: "https://github.com/AinkradHQ/AinkradThrall/releases/download/engine-image-v2/thrall-engine-image.tar.gz",
        sha256: "d92874d7089919d5e9daafac2550e73c3122816185232d3f52c8ae6b49c3d6e7")

    static let compose = Artifact(
        version: "v5.6.1",
        url: "https://github.com/docker/compose/releases/download/v5.6.1/docker-compose-darwin-aarch64",
        sha256: "fcce41226abd2b7b2936094e688bbd61284673dddafea542e08cb9a3b4423a8b")

    static let label = "com.ainkrad.thrall.engine"
    /// The Docker context the helper registers.
    static let contextName = "thrall"
    static let contextDirectory = "0c74d684c7bf7876e23301c2008a3e464bfcf55d828e78c43c8e0c40aba42514"
    static let imageFiles = ["Image", "initramfs", "rootfs.img", "manifest.json"]

    struct Paths: Sendable, Equatable {
        let root: URL
        let launchAgents: URL

        static var user: Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Paths(
                root: home.appendingPathComponent(".thrall"),
                launchAgents: home.appendingPathComponent("Library/LaunchAgents"))
        }

        var vm: URL { root.appendingPathComponent("vm") }
        var bin: URL { root.appendingPathComponent("bin") }
        var helper: URL { bin.appendingPathComponent("thrall-engine") }
        var compose: URL { bin.appendingPathComponent("docker-compose") }
        var engineLog: URL { root.appendingPathComponent("logs/engine.log") }
        var dockerSocket: URL { root.appendingPathComponent("run/docker.sock") }
        var plist: URL { launchAgents.appendingPathComponent("\(label).plist") }
        var status: URL { root.appendingPathComponent("run/status.json") }
        var config: URL { root.appendingPathComponent("engine.json") }
        var consoleLog: URL { root.appendingPathComponent("logs/console.log") }
        var dataDisk: URL { vm.appendingPathComponent("data.img") }
        /// The `thrall` entry in the Docker context store, which the helper
        /// registers under `sha256("thrall")`.
        var dockerContextMeta: URL {
            launchAgents.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".docker/contexts/meta/\(ThrallOwnEngine.contextDirectory)")
        }
        /// The version of each installed artifact, so an unchanged one is
        /// never downloaded again.
        func marker(_ name: String) -> URL { root.appendingPathComponent("versions/\(name)") }
    }

    /// The launchd job. `KeepAlive.Crashed` restarts the helper only when it
    /// dies on a signal: the helper restarts the VM itself, and a clean exit
    /// or a configuration error (exit 78) must stay down. `ExitTimeOut` is
    /// longer than the helper's 15 s guest shutdown, so `bootout` never cuts
    /// `dockerd` off mid-stop.
    static func launchAgentPlist(_ paths: Paths, startsAtLogin: Bool = true) throws -> Data {
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [paths.helper.path, "run"],
            "RunAtLoad": startsAtLogin,
            "KeepAlive": ["Crashed": true],
            "ExitTimeOut": 30,
            "StandardErrorPath": paths.engineLog.path,
            "StandardOutPath": paths.engineLog.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    /// Virtualization.framework runs Linux guests on Intel too, but the
    /// published image is arm64 only.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// The VM size in effect: `engine.json`, or the helper's own defaults.
    /// The defaults are restated here (half the cores up to 4, and 4 GB)
    /// because the helper's `ThrallVMSpec` is not compiled into the plugin.
    static func config(_ paths: Paths) -> ThrallEngineConfig {
        ThrallEngineConfig.read(from: paths.config)
            ?? ThrallEngineConfig(
                cpuCount: max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)), memoryGiB: 4)
    }

    /// The LaunchAgent's `RunAtLoad`, read back from the plist: the plist is
    /// the setting, so there is no second copy to drift from it.
    static func startsAtLogin(_ paths: Paths) -> Bool {
        guard let data = try? Data(contentsOf: paths.plist),
            let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return true }
        return job["RunAtLoad"] as? Bool ?? true
    }

    /// The helper built into this plugin bundle, at `Contents/Helpers`.
    static var bundledHelper: URL? {
        let url = Bundle(for: ThrallConnection.self).bundleURL
            .appendingPathComponent("Contents/Helpers/thrall-engine")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
