import Foundation

/// The VM's size. Settings will feed this in E4; until then it is the
/// defaults.
struct ThrallVMSpec: Sendable, Equatable {
    var cpuCount: Int
    var memoryBytes: UInt64
    var dataDiskBytes: UInt64

    static let gibibyte: UInt64 = 1 << 30

    /// Half the cores, capped at 4, and 4 GiB of memory. That is enough for
    /// a database plus two app containers without starving the host.
    static func defaults(processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> ThrallVMSpec {
        ThrallVMSpec(
            cpuCount: max(1, min(4, processorCount / 2)),
            memoryBytes: 4 * gibibyte,
            dataDiskBytes: 64 * gibibyte)
    }

    /// The guest kernel's command line. `rw` because the guest writes
    /// `/etc/resolv.conf` and logs to its root; user data still lives on the
    /// separate data disk, so replacing the root filesystem stays safe.
    ///
    /// `thrall.home` tells the guest's `thrall-home` service where to mount
    /// the shared home folder: the same path as on the Mac, so a compose bind
    /// mount like `./src:/app` resolves unchanged.
    static func kernelCommandLine(sharedHome: String?) -> String {
        let base = "console=hvc0 root=/dev/vda rootfstype=ext4 rw modules=virtio_blk,ext4"
        return sharedHome.map { "\(base) thrall.home=\($0)" } ?? base
    }

    /// The home folder to share, or nil when its path has whitespace: the
    /// kernel command line splits on it, and a half path would mount in the
    /// wrong place.
    static func sharedHome(_ path: String) -> String? {
        path.contains(where: \.isWhitespace) ? nil : path
    }
}
