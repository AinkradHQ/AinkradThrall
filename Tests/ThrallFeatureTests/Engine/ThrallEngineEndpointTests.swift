import Foundation
import Testing
@testable import ThrallFeature

@Suite("ThrallEngineEndpoint")
struct ThrallEngineEndpointTests {
    @Test("a unix socket URL becomes a path")
    func unixSocket() {
        #expect(ThrallEngineEndpoint.parse("unix:///Users/me/.orbstack/run/docker.sock")
            == .unixSocket(path: "/Users/me/.orbstack/run/docker.sock"))
    }

    @Test("a bare absolute path is accepted — it is what a settings field gets")
    func barePath() {
        #expect(ThrallEngineEndpoint.parse("/var/run/docker.sock")
            == .unixSocket(path: "/var/run/docker.sock"))
    }

    @Test("surrounding whitespace is trimmed")
    func trimmed() {
        #expect(ThrallEngineEndpoint.parse("  unix:///tmp/d.sock\n")
            == .unixSocket(path: "/tmp/d.sock"))
    }

    /// Refused, but **listed with a reason** — a context that vanishes from the
    /// switcher is a support call, and with three contexts configured here
    /// "which daemon am I looking at" is the failure mode the switcher exists
    /// to answer.
    @Test("a transport Thrall will not drive is unsupported, not dropped", arguments: [
        "tcp://10.0.0.4:2376", "ssh://user@host", "npipe:////./pipe/docker_engine",
        "fd://", "https://example.test:2376", "quic://weird",
    ])
    func unsupportedTransports(raw: String) throws {
        let endpoint = try #require(ThrallEngineEndpoint.parse(raw))
        #expect(!endpoint.isSupported)
        guard case .unsupported(_, _, let reason) = endpoint else {
            Issue.record("expected .unsupported")
            return
        }
        #expect(!reason.isEmpty, "an unsupported endpoint must be able to explain itself")
    }

    @Test("input that names nothing at all parses to nothing",
          arguments: ["", "   ", "docker.sock", "unix://relative/path", "unix://"])
    func namesNothing(raw: String) {
        #expect(ThrallEngineEndpoint.parse(raw) == nil)
    }

    /// The finding that made `engineKey` exist: on this machine
    /// `/var/run/docker.sock` is a symlink to `~/.orbstack/run/docker.sock`, so
    /// the implicit `default` context and `orbstack` are **one engine wearing
    /// two names**. Keyed on the literal path they would show as two engines,
    /// and every stack seen through both would duplicate.
    @Test("two paths to the same socket share one engine key",
          .enabled(if: FileManager.default.fileExists(atPath: "/var/run/docker.sock")))
    func symlinkedPathsShareAnEngineKey() throws {
        let viaPlatform = ThrallEngineEndpoint.unixSocket(path: "/var/run/docker.sock")
        let resolved = URL(fileURLWithPath: "/var/run/docker.sock")
            .resolvingSymlinksInPath().path
        let viaContext = ThrallEngineEndpoint.unixSocket(path: resolved)
        #expect(viaPlatform.engineKey == viaContext.engineKey)
        #expect(viaPlatform != viaContext, "the endpoints differ; only their engine key agrees")
    }

    @Test("an absent socket still yields a stable key rather than crashing")
    func absentSocketKey() {
        let endpoint = ThrallEngineEndpoint.unixSocket(path: "/nonexistent/docker.sock")
        #expect(endpoint.engineKey == "unix:/nonexistent/docker.sock")
    }

    @Test("a tilde is expanded, so ~/.docker and the absolute path agree")
    func tildeExpansion() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let viaTilde = ThrallEngineEndpoint.unixSocket(path: "~/.thrall-test.sock")
        #expect(viaTilde.engineKey == "unix:\(home)/.thrall-test.sock")
    }
}
