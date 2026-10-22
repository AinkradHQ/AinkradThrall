import Foundation

/// Where Thrall's engine keeps everything, under one root (`~/.thrall`).
///
/// The guest image (kernel, initramfs, root filesystem) is replaceable; the
/// data disk and the MAC address are not. Keeping them as separate files means
/// an image update swaps three files and never touches a volume.
struct ThrallEnginePaths: Sendable, Equatable {
    let root: URL
    /// Kernel, initramfs and root filesystem. Defaults to `<root>/vm`;
    /// overridable so a fresh `build/engine-image` boots without copying it.
    let imageDirectory: URL

    init(root: URL, imageDirectory: URL? = nil) {
        self.root = root
        self.imageDirectory = imageDirectory ?? root.appendingPathComponent("vm")
    }

    static func user(imageDirectory: URL? = nil) -> ThrallEnginePaths {
        ThrallEnginePaths(
            root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".thrall"),
            imageDirectory: imageDirectory)
    }

    var kernel: URL { imageDirectory.appendingPathComponent("Image") }
    var initialRamdisk: URL { imageDirectory.appendingPathComponent("initramfs") }
    var rootFilesystem: URL { imageDirectory.appendingPathComponent("rootfs.img") }

    var vmDirectory: URL { root.appendingPathComponent("vm") }
    var dataDisk: URL { vmDirectory.appendingPathComponent("data.img") }
    /// The guest's MAC, persisted so the NAT DHCP lease (and so the guest IP)
    /// stays the same across boots.
    var macAddress: URL { vmDirectory.appendingPathComponent("mac") }

    var statusFile: URL { root.appendingPathComponent("run/status.json") }
    var configFile: URL { root.appendingPathComponent("engine.json") }

    var logsDirectory: URL { root.appendingPathComponent("logs") }
    var consoleLog: URL { logsDirectory.appendingPathComponent("console.log") }

    /// The files the guest image must provide. A missing one is a
    /// configuration error, not something a restart can fix.
    var requiredImageFiles: [URL] { [kernel, initialRamdisk, rootFilesystem] }
}
