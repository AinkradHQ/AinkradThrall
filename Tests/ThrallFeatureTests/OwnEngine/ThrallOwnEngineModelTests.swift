import Foundation
import Testing

@testable import ThrallFeature

/// Every state the engine panel can show (mockup screens 3–5), derived from
/// what is on disk and in launchd.
@Suite("ThrallOwnEngineModel phases")
struct ThrallOwnEngineModelTests {
    private func phase(installed: Bool = true, loaded: Bool = true, _ status: ThrallEngineStatus?, arm: Bool = true)
        -> ThrallOwnEngineModel.Phase
    {
        ThrallOwnEngineModel.phase(installed: installed, loaded: loaded, status: status, isAppleSilicon: arm)
    }

    @Test("not installed, unsupported and stopped come before any status")
    func basics() {
        #expect(phase(installed: false, loaded: false, nil) == .notInstalled)
        #expect(phase(installed: false, loaded: false, nil, arm: false) == .unsupported)
        #expect(phase(loaded: false, nil) == .stopped)
    }

    @Test("a loaded job reads the helper's status, and no file yet means starting")
    func loaded() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(phase(nil) == .starting)
        #expect(phase(ThrallEngineStatus(phase: .running, runningSince: since)) == .running(since: since))
        #expect(phase(ThrallEngineStatus(phase: .restarting, retryInSeconds: 8)) == .restarting(retryIn: 8))
        #expect(phase(ThrallEngineStatus(phase: .stopping)) == .stopping)
    }

    /// launchd does not restart a configuration error, so the job is gone
    /// and only the status file can say why.
    @Test("a failed status wins even after the helper has exited")
    func failedOutlivesHelper() {
        let failed = ThrallEngineStatus(phase: .failed, failure: "rootfs.img does not exist")
        #expect(phase(loaded: false, failed) == .failed("rootfs.img does not exist"))
    }

    @Test("install rows mark earlier steps done and carry the fraction only on the active one")
    func installRows() {
        let rows = ThrallEngineInstallSteps.rows(for: .downloadingCompose(fraction: 0.4))
        #expect(rows.map(\.state) == [.done, .active, .pending, .pending])
        #expect(rows.map(\.fraction) == [nil, 0.4, nil, nil])
    }

    @Test("uninstall names volumes and repeats their count on the button")
    func uninstallWording() {
        let contents = ThrallEngineContents(
            containers: 14, images: 21, volumeNames: ["a", "b", "c", "d", "e", "optimus_db"])
        let message = ThrallConfirmations.uninstallEngine(contents)
        #expect(message.contains("14 containers, 6 volumes (a, b, c, d, and 2 more) and 21 images"))
        #expect(message.contains("project folders are not touched"))
        #expect(ThrallConfirmations.uninstallEngineButton(contents) == "Delete 6 volumes and uninstall")
        #expect(ThrallConfirmations.uninstallEngine(nil).contains("every container, volume and image"))
        #expect(ThrallConfirmations.uninstallEngineButton(nil) == "Uninstall")
    }

    @Test("menu titles only claim states Thrall knows")
    func menuTitles() {
        let thrall = ThrallEngineContext(name: "thrall", endpoint: .unixSocket(path: "/nonexistent/thrall.sock"))
        let gone = ThrallEngineContext(name: "desktop-linux", endpoint: .unixSocket(path: "/nonexistent/docker.sock"))
        let present = ThrallEngineContext(name: "orbstack", endpoint: .unixSocket(path: "/bin/sh"))
        #expect(
            ThrallEngineMenu.title(for: thrall, active: nil, activeState: .idle, ownEngine: .stopped)
                == "thrall — stopped")
        #expect(
            ThrallEngineMenu.title(for: gone, active: nil, activeState: .idle, ownEngine: .stopped)
                == "desktop-linux — not running")
        #expect(
            ThrallEngineMenu.title(for: present, active: nil, activeState: .idle, ownEngine: .stopped) == "orbstack")
        #expect(
            ThrallEngineMenu.title(for: present, active: present, activeState: .loaded, ownEngine: .stopped)
                == "orbstack — running")
    }

    @Test("uptime reads in minutes, then hours and minutes")
    func uptime() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ThrallEnginePanel.uptime(since: start, now: Date(timeIntervalSince1970: 59 * 60)) == "59m")
        #expect(ThrallEnginePanel.uptime(since: start, now: Date(timeIntervalSince1970: 192 * 60)) == "3h 12m")
    }
}
