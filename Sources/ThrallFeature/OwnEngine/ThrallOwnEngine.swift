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
        version: "engine-image-v1",
        url: "https://github.com/AinkradHQ/AinkradThrall/releases/download/engine-image-v1/thrall-engine-image.tar.gz",
        sha256: "4eeaacde0adad10498cb4c3da2c2b3eb03aef726d00320f65459a137d4ab5c77")

    static let compose = Artifact(
        version: "v5.6.1",
        url: "https://github.com/docker/compose/releases/download/v5.6.1/docker-compose-darwin-aarch64",
        sha256: "fcce41226abd2b7b2936094e688bbd61284673dddafea542e08cb9a3b4423a8b")

    static let label = "com.ainkrad.thrall.engine"
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
        /// The version of each installed artifact, so an unchanged one is
        /// never downloaded again.
        func marker(_ name: String) -> URL { root.appendingPathComponent("versions/\(name)") }
    }

    /// The launchd job. `KeepAlive.Crashed` restarts the helper only when it
    /// dies on a signal: the helper restarts the VM itself, and a clean exit
    /// or a configuration error (exit 78) must stay down. `ExitTimeOut` is
    /// longer than the helper's 15 s guest shutdown, so `bootout` never cuts
    /// `dockerd` off mid-stop.
    static func launchAgentPlist(_ paths: Paths) throws -> Data {
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [paths.helper.path, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["Crashed": true],
            "ExitTimeOut": 30,
            "StandardErrorPath": paths.engineLog.path,
            "StandardOutPath": paths.engineLog.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    /// The helper built into this plugin bundle, at `Contents/Helpers`.
    static var bundledHelper: URL? {
        let url = Bundle(for: ThrallConnection.self).bundleURL
            .appendingPathComponent("Contents/Helpers/thrall-engine")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
