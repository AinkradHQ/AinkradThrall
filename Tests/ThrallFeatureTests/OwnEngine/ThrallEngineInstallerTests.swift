import Foundation
import Testing

@testable import ThrallFeature

/// Stands in for launchd and the network. `tar` is real: the image really is
/// unpacked, which is the part worth testing.
private final class FakeSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var loaded = false
    private var downloads: [URL] = []
    let artifacts: [URL: Data]
    let scratch: URL
    /// The helper's socket, which the fake helper removes on `bootout` when
    /// `exitsOnBootout` is true, as the real one does once its VM is down.
    var socket: URL?
    var exitsOnBootout = true

    init(artifacts: [URL: Data], scratch: URL, loaded: Bool = false) {
        self.artifacts = artifacts
        self.scratch = scratch
        self.loaded = loaded
    }

    var launchctlCalls: [String] { lock.withLock { calls } }
    var downloaded: [URL] { lock.withLock { downloads } }
    var isLoaded: Bool { lock.withLock { loaded } }

    func download(_ url: URL) throws -> URL {
        lock.withLock { downloads.append(url) }
        let file = scratch.appendingPathComponent("download-\(UUID().uuidString)")
        try artifacts[url, default: Data()].write(to: file)
        return file
    }

    func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        guard executable == "/bin/launchctl" else {
            return try ThrallEngineInstaller.spawn(executable, arguments)
        }
        return lock.withLock {
            switch arguments.first {
            case "print": return loaded ? 0 : 113
            case "bootstrap":
                calls.append("bootstrap")
                loaded = true
            case "bootout":
                calls.append("bootout")
                loaded = false
                if exitsOnBootout, let socket { try? FileManager.default.removeItem(at: socket) }
            default: break
            }
            return 0
        }
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ThrallEngineInstaller.Step] = []
    var all: [ThrallEngineInstaller.Step] { lock.withLock { steps } }
    func append(_ step: ThrallEngineInstaller.Step) { lock.withLock { steps.append(step) } }
}

@Suite("ThrallEngineInstaller")
struct ThrallEngineInstallerTests {
    private let scratch: URL
    private let paths: ThrallOwnEngine.Paths
    private let helper: URL
    private let imageURL = URL(string: "https://example.test/image.tar.gz")!
    private let composeURL = URL(string: "https://example.test/docker-compose")!

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        paths = ThrallOwnEngine.Paths(
            root: scratch.appendingPathComponent("home/.thrall"),
            launchAgents: scratch.appendingPathComponent("home/Library/LaunchAgents"))
        helper = scratch.appendingPathComponent("thrall-engine")
        try Data("helper v1".utf8).write(to: helper)
    }

    /// A real tar.gz of the four image files, each holding its own name.
    private func imageArchive(tag: String = "1") throws -> Data {
        let source = scratch.appendingPathComponent("image-src-\(tag)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for file in ThrallOwnEngine.imageFiles {
            try Data("\(file) \(tag)".utf8).write(to: source.appendingPathComponent(file))
        }
        let archive = scratch.appendingPathComponent("image-\(tag).tar.gz")
        let status = try ThrallEngineInstaller.spawn(
            "/usr/bin/tar", ["-czf", archive.path, "-C", source.path] + ThrallOwnEngine.imageFiles)
        #expect(status == 0)
        return try Data(contentsOf: archive)
    }

    private func sha(_ data: Data) throws -> String {
        let file = scratch.appendingPathComponent("sha-\(UUID().uuidString)")
        try data.write(to: file)
        return try ThrallEngineInstaller.sha256(of: file)
    }

    private func installer(
        _ system: FakeSystem, image: Data, compose: Data, imageVersion: String = "image-1",
        imageSHA: String? = nil
    ) throws -> ThrallEngineInstaller {
        ThrallEngineInstaller(
            paths: paths,
            helperSource: helper,
            image: .init(version: imageVersion, url: imageURL.absoluteString, sha256: try imageSHA ?? sha(image)),
            compose: .init(version: "compose-1", url: composeURL.absoluteString, sha256: try sha(compose)),
            download: { url, progress in
                progress(0.5)
                return try system.download(url)
            },
            run: { try system.run($0, $1) },
            userID: 501)
    }

    @Test("a fresh install unpacks the image, installs compose and the helper, and starts the job")
    func freshInstall() async throws {
        let image = try imageArchive()
        let compose = Data("compose binary".utf8)
        let system = FakeSystem(artifacts: [imageURL: image, composeURL: compose], scratch: scratch)
        try await installer(system, image: image, compose: compose).install()

        for file in ThrallOwnEngine.imageFiles {
            let contents = try String(contentsOf: paths.vm.appendingPathComponent(file), encoding: .utf8)
            #expect(contents == "\(file) 1")
        }
        #expect(try Data(contentsOf: paths.compose) == compose)
        #expect(FileManager.default.isExecutableFile(atPath: paths.compose.path))
        #expect(FileManager.default.isExecutableFile(atPath: paths.helper.path))
        #expect(FileManager.default.fileExists(atPath: paths.plist.path))
        #expect(system.launchctlCalls == ["bootstrap"])
        #expect(system.isLoaded)
    }

    /// Running containers must survive a re-run that has nothing to do.
    @Test("a second install with nothing changed downloads nothing and does not restart the engine")
    func idempotent() async throws {
        let image = try imageArchive()
        let compose = Data("compose binary".utf8)
        let system = FakeSystem(artifacts: [imageURL: image, composeURL: compose], scratch: scratch)
        let subject = try installer(system, image: image, compose: compose)
        try await subject.install()
        try await subject.install()
        #expect(system.downloaded.count == 2)
        #expect(system.launchctlCalls == ["bootstrap"])
    }

    @Test("a checksum mismatch installs nothing and leaves a running engine alone")
    func checksumMismatch() async throws {
        let image = try imageArchive()
        let compose = Data("compose binary".utf8)
        let system = FakeSystem(artifacts: [imageURL: image, composeURL: compose], scratch: scratch, loaded: true)
        let subject = try installer(system, image: image, compose: compose, imageSHA: String(repeating: "0", count: 64))
        await #expect(throws: ThrallEngineInstallError.self) { try await subject.install() }
        #expect(!FileManager.default.fileExists(atPath: paths.vm.appendingPathComponent("rootfs.img").path))
        #expect(!FileManager.default.fileExists(atPath: paths.plist.path))
        #expect(system.launchctlCalls.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        #expect(!leftovers.contains { $0.hasPrefix(".download-") })
    }

    /// Replacing `rootfs.img` under a running guest corrupts it.
    @Test("a new image stops the engine before replacing files, then starts it again")
    func imageUpdateStopsFirst() async throws {
        let compose = Data("compose binary".utf8)
        let first = try imageArchive(tag: "1")
        let system1 = FakeSystem(artifacts: [imageURL: first, composeURL: compose], scratch: scratch)
        try await installer(system1, image: first, compose: compose).install()

        let second = try imageArchive(tag: "2")
        let system2 = FakeSystem(artifacts: [imageURL: second, composeURL: compose], scratch: scratch, loaded: true)
        try await installer(system2, image: second, compose: compose, imageVersion: "image-2").install()
        #expect(system2.launchctlCalls == ["bootout", "bootstrap"])
        #expect(system2.downloaded == [imageURL])
        let rootfs = try String(contentsOf: paths.vm.appendingPathComponent("rootfs.img"), encoding: .utf8)
        #expect(rootfs == "rootfs.img 2")
    }

    @Test("stop waits for the helper to remove its socket, and times out rather than carrying on")
    func stopWaitsForShutdown() async throws {
        try FileManager.default.createDirectory(
            at: paths.dockerSocket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: paths.dockerSocket)
        let system = FakeSystem(artifacts: [:], scratch: scratch, loaded: true)
        system.socket = paths.dockerSocket
        var subject = try installer(system, image: Data(), compose: Data())
        try await subject.stop()
        #expect(!FileManager.default.fileExists(atPath: paths.dockerSocket.path))

        try Data().write(to: paths.dockerSocket)
        let hung = FakeSystem(artifacts: [:], scratch: scratch, loaded: true)
        hung.socket = paths.dockerSocket
        hung.exitsOnBootout = false
        subject = try installer(hung, image: Data(), compose: Data())
        subject.stopTimeout = .milliseconds(300)
        await #expect(throws: ThrallEngineInstallError.stopTimedOut) { try await subject.stop() }
    }

    @Test("progress walks the steps in order and reports download fractions")
    func progressSteps() async throws {
        let image = try imageArchive()
        let compose = Data("compose binary".utf8)
        let system = FakeSystem(artifacts: [imageURL: image, composeURL: compose], scratch: scratch)
        let steps = StepLog()
        try await installer(system, image: image, compose: compose).install { steps.append($0) }
        #expect(
            steps.all == [
                .downloadingImage(fraction: nil), .downloadingImage(fraction: 0.5),
                .downloadingCompose(fraction: nil), .downloadingCompose(fraction: 0.5),
                .verifying, .starting,
            ])
    }

    @Test("start at login rewrites RunAtLoad and leaves a running engine alone")
    func startsAtLogin() async throws {
        let image = try imageArchive()
        let compose = Data("compose binary".utf8)
        let system = FakeSystem(artifacts: [imageURL: image, composeURL: compose], scratch: scratch)
        let subject = try installer(system, image: image, compose: compose)
        try await subject.install()
        try subject.setStartsAtLogin(false)
        let job = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.plist), format: nil)
                as? [String: Any])
        #expect(job["RunAtLoad"] as? Bool == false)
        #expect(system.launchctlCalls == ["bootstrap"])
    }

    @Test("an installed engine needs an update when this build pins a new image or carries a new helper")
    func needsUpdate() async throws {
        let image = try imageArchive()
        let compose = Data("compose binary".utf8)
        let system = FakeSystem(artifacts: [imageURL: image, composeURL: compose], scratch: scratch)
        let subject = try installer(system, image: image, compose: compose)
        #expect(!subject.needsUpdate)
        try await subject.install()
        #expect(!subject.needsUpdate)
        #expect(try installer(system, image: image, compose: compose, imageVersion: "image-2").needsUpdate)
        try Data("helper v2".utf8).write(to: helper)
        #expect(subject.needsUpdate)
    }

    @Test("uninstall stops the engine and removes the job, ~/.thrall and the Docker context")
    func uninstall() async throws {
        let image = try imageArchive()
        let compose = Data("compose binary".utf8)
        let system = FakeSystem(artifacts: [imageURL: image, composeURL: compose], scratch: scratch)
        let subject = try installer(system, image: image, compose: compose)
        try await subject.install()
        try FileManager.default.createDirectory(at: paths.dockerContextMeta, withIntermediateDirectories: true)
        #expect(subject.isInstalled)

        try await subject.uninstall()
        #expect(system.launchctlCalls == ["bootstrap", "bootout"])
        for url in [paths.plist, paths.root, paths.dockerContextMeta] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(!subject.isInstalled)
    }

    @Test("a build without the helper refuses before downloading anything")
    func helperMissing() async throws {
        let system = FakeSystem(artifacts: [:], scratch: scratch)
        var subject = try installer(system, image: Data(), compose: Data())
        subject.helperSource = nil
        await #expect(throws: ThrallEngineInstallError.helperMissing) { try await subject.install() }
        #expect(system.downloaded.isEmpty)
    }

    @Test("the launchd job restarts the helper only on a crash, and outlasts its guest shutdown")
    func launchAgentPlist() throws {
        let data = try ThrallOwnEngine.launchAgentPlist(paths)
        let job = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(job["Label"] as? String == "com.ainkrad.thrall.engine")
        #expect(job["ProgramArguments"] as? [String] == [paths.helper.path, "run"])
        #expect(job["KeepAlive"] as? [String: Bool] == ["Crashed": true])
        #expect((job["ExitTimeOut"] as? Int ?? 0) > 15)
    }
}
