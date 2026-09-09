import Foundation
import Testing
@testable import ThrallFeature

/// The join: request out, framing events in. Everything here runs against
/// `ScriptedByteStream` except the last test, which is gated on a real socket
/// being present.
@Suite("ThrallHTTPExchange")
struct ThrallHTTPExchangeTests {
    @Test("a chunked response is read whole and the request reached the wire")
    func unaryChunked() async throws {
        let stream = ScriptedByteStream.splitting(RawResponses.containersChunked, every: 37)
        let request = ThrallHTTPRequest(target: "/v1.51/containers/json")
        let response = try await ThrallHTTPExchange.perform(request, over: stream)

        #expect(response.head.statusCode == 200)
        #expect(response.body == RawResponses.containersBody)
        #expect(await stream.connectCount == 1)
        let sent = String(decoding: await stream.written, as: UTF8.self)
        #expect(sent.hasPrefix("GET /v1.51/containers/json HTTP/1.1\r\n"))
        // The body really is JSON, not a chunk-size line that leaked through.
        let decoded = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        #expect(try #require(decoded).count == 2)
    }

    @Test("a Content-Length response is read whole")
    func unaryContentLength() async throws {
        let stream = ScriptedByteStream.splitting(RawResponses.versionContentLength, every: 5)
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(target: "/v1.51/version"), over: stream)
        #expect(response.body == RawResponses.versionBody)
    }

    /// A body with no declared length ends when the connection does, which for
    /// a `Connection: close` response is the only terminator there is.
    @Test("an unframed body terminates on the peer closing")
    func unaryUntilClose() async throws {
        let stream = ScriptedByteStream(reads: [
            RawResponses.bytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nopa"),
            RawResponses.bytes("que"),
        ])
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(target: "/v1.51/_ping"), over: stream)
        #expect(response.body == Data("opaque".utf8))
    }

    /// A unary caller has nowhere to put a hijacked pipe, and returning the
    /// head alone would leak the socket while looking like success.
    @Test("a unary call refuses an upgrade rather than losing the pipe")
    func unaryRefusesUpgrade() async throws {
        let stream = ScriptedByteStream(reads: [
            RawResponses.bytes("HTTP/1.1 101 UPGRADED\r\nUpgrade: tcp\r\n\r\nroot@abc:/# "),
        ])
        await #expect(throws: ThrallTransportError.self) {
            try await ThrallHTTPExchange.perform(
                ThrallHTTPRequest(method: "POST", target: "/v1.51/containers/abc/attach"),
                over: stream)
        }
    }

    @Test("a body over the cap is refused rather than accumulated")
    func bodyCap() async throws {
        let stream = ScriptedByteStream.splitting(RawResponses.containersChunked, every: 64)
        await #expect(throws: ThrallTransportError.self) {
            try await ThrallHTTPExchange.perform(
                ThrallHTTPRequest(target: "/v1.51/containers/json"),
                over: stream,
                maximumBodyLength: 16)
        }
    }

    @Test("the reader hands events out one at a time and then nil")
    func readerSequence() async throws {
        let stream = ScriptedByteStream.splitting(RawResponses.versionContentLength, every: 11)
        let reader = ThrallHTTPResponseReader(stream: stream)
        var kinds: [String] = []
        while let event = try await reader.next(timeout: .seconds(1)) {
            switch event {
            case .head: kinds.append("head")
            case .body: kinds.append("body")
            case .trailers: kinds.append("trailers")
            case .end: kinds.append("end")
            case .upgraded: kinds.append("upgraded")
            }
        }
        #expect(kinds.first == "head")
        #expect(kinds.last == "end")
        #expect(try await reader.next(timeout: .seconds(1)) == nil)
    }

    // MARK: - The hijacked stream

    /// The bytes past the header terminator are the container's first output.
    /// Handing back the bare connection instead loses them — which is a shell
    /// prompt that goes missing once a week and never on demand.
    @Test("a hijacked stream returns the residual before reading the socket")
    func hijackReturnsResidualFirst() async throws {
        let upstream = ScriptedByteStream(reads: [Data("total 0\n".utf8)])
        let hijacked = ThrallHijackedStream(upstream: upstream, residual: Data("root@abc:/# ".utf8))
        #expect(try await hijacked.read(timeout: .seconds(1)) == Data("root@abc:/# ".utf8))
        #expect(try await hijacked.read(timeout: .seconds(1)) == Data("total 0\n".utf8))
        await #expect(throws: ThrallTransportError.closed) {
            _ = try await hijacked.read(timeout: .seconds(1))
        }
    }

    @Test("an empty residual reads straight through")
    func hijackWithoutResidual() async throws {
        let upstream = ScriptedByteStream(reads: [Data("first".utf8)])
        let hijacked = ThrallHijackedStream(upstream: upstream, residual: Data())
        #expect(try await hijacked.read(timeout: .seconds(1)) == Data("first".utf8))
    }

    @Test("writes go through to the socket under it")
    func hijackWrites() async throws {
        let upstream = ScriptedByteStream(reads: [])
        let hijacked = ThrallHijackedStream(upstream: upstream, residual: Data())
        try await hijacked.send(Data("ls -la\n".utf8))
        #expect(await upstream.written == Data("ls -la\n".utf8))
    }

    // MARK: - Against a real engine, when there is one

    /// The one test that needs a daemon, and it is skipped when there is none
    /// so the suite stays honest on a machine with no engine. Everything above
    /// is the actual contract; this only confirms the contract describes
    /// reality.
    @Test("a live engine answers GET /version over AF_UNIX",
          .enabled(if: LiveEngine.socketPath != nil))
    func liveVersion() async throws {
        let path = try #require(LiveEngine.socketPath)
        let connection = ThrallConnection(socketPath: path)
        let response = try await ThrallHTTPExchange.perform(
            // Unversioned on purpose: the version handshake cannot itself
            // depend on a version. Task C builds the negotiation on top.
            ThrallHTTPRequest(target: "/version"), over: connection)
        await connection.close()

        #expect(response.head.statusCode == 200)
        #expect(response.head.contentType == "application/json")
        let payload = try #require(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let apiVersion = try #require(payload["ApiVersion"] as? String)
        #expect(apiVersion.hasPrefix("1."))
    }

    @Test("a socket path with nothing listening fails fast instead of waiting")
    func deadSocketFailsFast() async throws {
        // `NWConnection` reports AF_UNIX unreachability as `.waiting` and would
        // retry it forever; ThrallConnection treats that as a failure so an
        // engine-down connect answers in milliseconds rather than at the
        // connect timeout.
        let connection = ThrallConnection(socketPath: "/nonexistent/thrall-test.sock",
                                          connectTimeout: .seconds(30))
        let started = ContinuousClock.now
        await #expect(throws: ThrallTransportError.self) {
            try await connection.connect()
        }
        #expect(started.duration(to: .now) < .seconds(5))
        await connection.close()
    }
}

/// Locates a live engine socket, or nothing. Deliberately dumb — real context
/// resolution (`~/.docker/config.json`, `contexts/meta/*/meta.json`) is Task C
/// and belongs in the feature, not in a test helper.
enum LiveEngine {
    static let socketPath: String? = {
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"],
           host.hasPrefix("unix://") {
            let path = String(host.dropFirst("unix://".count))
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.docker/run/docker.sock",
            "\(home)/.rd/docker.sock",
            "/var/run/docker.sock",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }()
}
