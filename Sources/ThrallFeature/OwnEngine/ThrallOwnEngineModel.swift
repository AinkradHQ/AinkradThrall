import AinkradAppKit
import Foundation

/// Thrall's own engine as the UI sees it: one phase, read from launchd and
/// the helper's `status.json`, plus the verbs on it.
@MainActor
final class ThrallOwnEngineModel: ObservableObject {
    enum Phase: Equatable {
        /// Not an Apple silicon Mac: no button that cannot work.
        case unsupported
        case notInstalled
        case installing(ThrallEngineInstaller.Step)
        case installFailed(String)
        case stopped
        case starting
        case running(since: Date?)
        case stopping
        case restarting(retryIn: Int?)
        /// A configuration error: the helper exited and launchd will not
        /// restart it.
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isInstalled: Bool {
            switch self {
            case .unsupported, .notInstalled, .installing, .installFailed: return false
            default: return true
            }
        }
    }

    @Published private(set) var phase: Phase = .notInstalled
    @Published private(set) var status: ThrallEngineStatus?
    /// The data disk's real cost on this Mac (allocated, not apparent).
    @Published private(set) var diskUsedBytes: Int64?
    /// The data disk's apparent size: the most it can grow to.
    @Published private(set) var diskSizeBytes: Int64?
    /// The guest console's last lines, read while the engine boots.
    @Published private(set) var consoleTail: [String] = []
    /// This build carries a newer image, compose or helper than the
    /// installed engine. Updating restarts the engine, so it waits for the
    /// user's click.
    @Published private(set) var updateAvailable = false
    /// A verb in flight (start, stop, restart, uninstall), for its button.
    @Published private(set) var isBusy = false
    /// The last verb's failure, shown in the panel until the next verb.
    @Published var actionError: String?

    /// A port that just became conflicted, announced once as a toast.
    var onNewConflict: ((Int) -> Void)?
    /// The engine finished installing or starting; the view model re-resolves
    /// contexts and refreshes.
    var onBecameReady: (() -> Void)?

    private(set) var installer: ThrallEngineInstaller
    private let isAppleSilicon: Bool
    private var installTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var knownConflicts: Set<Int> = []

    init(
        installer: ThrallEngineInstaller = ThrallEngineInstaller(),
        isAppleSilicon: Bool = ThrallOwnEngine.isAppleSilicon
    ) {
        self.installer = installer
        self.isAppleSilicon = isAppleSilicon
        // A reinstall must keep the user's choice, not reset it to on.
        self.installer.startsAtLogin = ThrallOwnEngine.startsAtLogin(installer.paths)
    }

    var paths: ThrallOwnEngine.Paths { installer.paths }

    // MARK: - Reading

    /// The phase from what is on disk and in launchd. Pure, so every state
    /// in the mockups is a unit test.
    nonisolated static func phase(
        installed: Bool, loaded: Bool, status: ThrallEngineStatus?, isAppleSilicon: Bool
    ) -> Phase {
        guard isAppleSilicon else { return .unsupported }
        guard installed else { return .notInstalled }
        // A failed status survives the helper's exit on purpose.
        if let status, status.phase == .failed {
            return .failed(status.failure ?? "Thrall's engine cannot start.")
        }
        guard loaded else { return .stopped }
        switch status?.phase {
        case nil, .starting: return .starting
        case .running: return .running(since: status?.runningSince)
        case .stopping: return .stopping
        case .restarting: return .restarting(retryIn: status?.retryInSeconds)
        case .failed: return .failed(status?.failure ?? "Thrall's engine cannot start.")
        }
    }

    func refresh() async {
        if case .installing = phase { return }
        let installer = self.installer
        let (installed, loaded, update) = await Task.detached {
            let installed = installer.isInstalled
            return (installed, installed && installer.isLoaded(), installer.needsUpdate)
        }.value
        updateAvailable = update
        let status = ThrallEngineStatus.read(from: paths.status)
        let wasRunning = phase.isRunning
        let next = Self.phase(installed: installed, loaded: loaded, status: status, isAppleSilicon: isAppleSilicon)
        if case .installFailed = phase, next == .notInstalled { return }
        self.status = status
        phase = next
        diskUsedBytes = installed ? Self.allocatedSize(of: paths.dataDisk) : nil
        diskSizeBytes =
            installed ? (try? paths.dataDisk.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) : nil
        consoleTail = next == .starting ? Self.tail(of: paths.consoleLog, lines: 6) : []
        announceNewConflicts(status?.conflictedPorts ?? [])
        if next.isRunning, !wasRunning { onBecameReady?() }
    }

    /// Polls every 3 s while a Thrall window is open. One `launchctl print`
    /// and one small file read per tick.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Verbs

    func install() {
        guard installTask == nil else { return }
        actionError = nil
        phase = .installing(.downloadingImage(fraction: nil))
        let installer = self.installer
        // Steps arrive from the installer's own context; each hops to the
        // main actor, and a late one after a cancel is dropped.
        let onStep: @Sendable (ThrallEngineInstaller.Step) -> Void = { [weak self] step in
            Task { @MainActor in
                guard let self, case .installing = self.phase else { return }
                self.phase = .installing(step)
            }
        }
        installTask = Task { [weak self] in
            do {
                try await installer.install(progress: onStep)
                self?.finishInstall(failure: nil)
            } catch is CancellationError {
                self?.finishInstall(failure: nil)
            } catch let error as URLError where error.code == .cancelled {
                self?.finishInstall(failure: nil)
            } catch {
                self?.finishInstall(failure: Self.sentence(for: error))
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func start() { perform { try $0.start() } }
    func stop() { perform { try await $0.stop() } }
    func restart() { perform { try await $0.restart() } }
    func uninstall() { perform { try await $0.uninstall() } }

    func setStartsAtLogin(_ on: Bool) {
        installer.startsAtLogin = on
        do {
            try installer.setStartsAtLogin(on)
        } catch {
            actionError = Self.sentence(for: error)
        }
    }

    func writeConfig(_ config: ThrallEngineConfig) {
        do {
            try installer.writeConfig(config)
        } catch {
            actionError = Self.sentence(for: error)
        }
    }

    private func perform(_ verb: @escaping @Sendable (ThrallEngineInstaller) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        actionError = nil
        let installer = self.installer
        Task { [weak self] in
            do {
                try await verb(installer)
            } catch {
                self?.actionError = Self.sentence(for: error)
            }
            self?.isBusy = false
            await self?.refresh()
        }
    }

    private func finishInstall(failure: String?) {
        installTask = nil
        if let failure {
            phase = .installFailed(failure)
        } else {
            phase = .notInstalled
            Task { await refresh() }
        }
    }

    private func announceNewConflicts(_ ports: [Int]) {
        let current = Set(ports)
        for port in current.subtracting(knownConflicts).sorted() { onNewConflict?(port) }
        knownConflicts = current
    }

    #if DEBUG
    /// Puts the model in a state without launchd or a VM, for the
    /// screenshot sweep. Debug builds only.
    func preview(
        phase: Phase, status: ThrallEngineStatus? = nil, diskUsed: Int64? = nil, diskSize: Int64? = nil,
        console: [String] = []
    ) {
        self.phase = phase
        self.status = status
        diskUsedBytes = diskUsed
        diskSizeBytes = diskSize
        consoleTail = console
    }
    #endif

    // MARK: - Helpers

    nonisolated static func sentence(for error: Error) -> String {
        if let error = error as? ThrallEngineInstallError { return error.description }
        if let error = error as? URLError { return "The download failed: \(error.localizedDescription)" }
        return error.localizedDescription
    }

    nonisolated static func allocatedSize(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(Int64.init)
    }

    nonisolated static func tail(of url: URL, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).suffix(lines).map(String.init)
    }
}
