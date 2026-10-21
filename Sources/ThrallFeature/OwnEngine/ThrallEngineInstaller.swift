import CryptoKit
import Foundation

enum ThrallEngineInstallError: Error, Equatable, CustomStringConvertible {
    case helperMissing
    case checksumMismatch(artifact: String, expected: String, actual: String)
    case commandFailed(command: String, status: Int32)
    case stopTimedOut

    var description: String {
        switch self {
        case .helperMissing:
            return "This Thrall build does not contain the thrall-engine helper."
        case .checksumMismatch(let artifact, let expected, let actual):
            return
                "\(artifact) failed verification (expected SHA-256 \(expected), got \(actual)). Nothing was installed."
        case .commandFailed(let command, let status):
            return "\(command) failed with exit status \(status)."
        case .stopTimedOut:
            return "Thrall's engine did not finish shutting down. Nothing was replaced."
        }
    }
}

/// Installs, starts and stops Thrall's own engine.
///
/// The seams (`download`, `run`) exist so the whole install is tested without
/// a network, launchd or a VM.
struct ThrallEngineInstaller: Sendable {
    enum Step: Equatable, Sendable {
        case downloadingImage, downloadingCompose, installingHelper, starting
    }

    typealias Download = @Sendable (URL) async throws -> URL
    typealias Run = @Sendable (_ executable: String, _ arguments: [String]) throws -> Int32

    var paths: ThrallOwnEngine.Paths
    var helperSource: URL?
    var image: ThrallOwnEngine.Artifact
    var compose: ThrallOwnEngine.Artifact
    var download: Download
    var run: Run
    var userID: uid_t
    /// How long `stop()` waits for the guest to finish shutting down. Longer
    /// than the helper's own 15 s grace before it forces the VM off.
    var stopTimeout: Duration = .seconds(35)

    init(
        paths: ThrallOwnEngine.Paths = .user,
        helperSource: URL? = ThrallOwnEngine.bundledHelper,
        image: ThrallOwnEngine.Artifact = ThrallOwnEngine.image,
        compose: ThrallOwnEngine.Artifact = ThrallOwnEngine.compose,
        download: @escaping Download = Self.urlSessionDownload,
        run: @escaping Run = Self.spawn,
        userID: uid_t = getuid()
    ) {
        self.paths = paths
        self.helperSource = helperSource
        self.image = image
        self.compose = compose
        self.download = download
        self.run = run
        self.userID = userID
    }

    private var service: String { "gui/\(userID)/\(ThrallOwnEngine.label)" }

    // MARK: - Install

    /// Brings everything up to date and leaves the engine running.
    ///
    /// The engine is stopped **before** anything it uses is replaced:
    /// swapping `rootfs.img` under a running guest corrupts it. An install
    /// with nothing to change does not stop it at all, so running containers
    /// survive a re-run.
    func install(progress: @Sendable (Step) -> Void = { _ in }) async throws {
        guard let helperSource else { throw ThrallEngineInstallError.helperMissing }
        let fileManager = FileManager.default
        for directory in [paths.vm, paths.bin, paths.engineLog.deletingLastPathComponent(), paths.launchAgents] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Download and verify first, so a failed download leaves the
        // installed engine exactly as it was.
        var stagedImage: URL?
        if installedVersion("image") != image.version {
            progress(.downloadingImage)
            stagedImage = try await fetchVerified(image, name: "engine image")
        }
        var stagedCompose: URL?
        if installedVersion("compose") != compose.version || !fileManager.isExecutableFile(atPath: paths.compose.path) {
            progress(.downloadingCompose)
            stagedCompose = try await fetchVerified(compose, name: "docker-compose")
        }
        progress(.installingHelper)
        let helperChanged = !fileManager.contentsEqual(atPath: helperSource.path, andPath: paths.helper.path)
        let plist = try ThrallOwnEngine.launchAgentPlist(paths)
        let plistChanged = (try? Data(contentsOf: paths.plist)) != plist

        if stagedImage != nil || helperChanged || plistChanged, isLoaded() {
            try await stop()
        }
        if let stagedImage {
            try extractImage(stagedImage)
            try markInstalled("image", image.version)
        }
        if let stagedCompose {
            try replace(paths.compose, with: stagedCompose, executable: true)
            try markInstalled("compose", compose.version)
        }
        if helperChanged {
            let copy = paths.bin.appendingPathComponent(".thrall-engine.new")
            try? fileManager.removeItem(at: copy)
            try fileManager.copyItem(at: helperSource, to: copy)
            try replace(paths.helper, with: copy, executable: true)
        }
        if plistChanged {
            try plist.write(to: paths.plist, options: .atomic)
        }
        progress(.starting)
        try start()
    }

    // MARK: - Control

    func isLoaded() -> Bool {
        (try? run("/bin/launchctl", ["print", service])) == 0
    }

    func start() throws {
        guard !isLoaded() else { return }
        try check("/bin/launchctl", ["bootstrap", "gui/\(userID)", paths.plist.path])
    }

    /// Stops the helper and returns once the guest is down.
    ///
    /// `launchctl bootout` returns as soon as it has sent SIGTERM, while the
    /// guest still has seconds of shutdown ahead. The helper removes its
    /// Docker socket only after the VM has stopped, so the socket going away
    /// is the signal that the image files are safe to replace.
    func stop() async throws {
        guard isLoaded() else { return }
        try check("/bin/launchctl", ["bootout", service])
        let deadline = ContinuousClock.now + stopTimeout
        while FileManager.default.fileExists(atPath: paths.dockerSocket.path) {
            guard ContinuousClock.now < deadline else { throw ThrallEngineInstallError.stopTimedOut }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Steps

    private func installedVersion(_ name: String) -> String? {
        try? String(contentsOf: paths.marker(name), encoding: .utf8)
    }

    private func markInstalled(_ name: String, _ version: String) throws {
        let marker = paths.marker(name)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try version.write(to: marker, atomically: true, encoding: .utf8)
    }

    private func fetchVerified(_ artifact: ThrallOwnEngine.Artifact, name: String) async throws -> URL {
        guard let url = URL(string: artifact.url) else { throw URLError(.badURL) }
        let downloaded = try await download(url)
        let staged = paths.root.appendingPathComponent(".download-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: downloaded, to: staged)
        let actual = try Self.sha256(of: staged)
        guard actual == artifact.sha256 else {
            try? FileManager.default.removeItem(at: staged)
            throw ThrallEngineInstallError.checksumMismatch(artifact: name, expected: artifact.sha256, actual: actual)
        }
        return staged
    }

    /// Unpacks into a staging directory, then moves each file over the old
    /// one. bsdtar restores `rootfs.img` sparse.
    private func extractImage(_ archive: URL) throws {
        let fileManager = FileManager.default
        let staging = paths.vm.appendingPathComponent(".staging")
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: archive)
        }
        try check("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path] + ThrallOwnEngine.imageFiles)
        for file in ThrallOwnEngine.imageFiles {
            try replace(paths.vm.appendingPathComponent(file), with: staging.appendingPathComponent(file))
        }
    }

    private func replace(_ destination: URL, with source: URL, executable: Bool = false) throws {
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    private func check(_ executable: String, _ arguments: [String]) throws {
        let status = try run(executable, arguments)
        guard status == 0 else {
            throw ThrallEngineInstallError.commandFailed(
                command: ([executable] + arguments.prefix(1)).joined(separator: " "), status: status)
        }
    }

    // MARK: - Production seams

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static let urlSessionDownload: Download = { url in
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return file
    }

    static let spawn: Run = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
