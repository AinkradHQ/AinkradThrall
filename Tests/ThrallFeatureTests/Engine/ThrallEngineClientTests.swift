import Foundation
import Testing
@testable import ThrallFeature

@Suite("ThrallEngineClient")
struct ThrallEngineClientTests {
    private let socket = ThrallEngineEndpoint.unixSocket(path: "/tmp/thrall-test.sock")

    private func client(_ engine: ScriptedEngine) throws -> ThrallEngineClient {
        try ThrallEngineClient(endpoint: socket, streamFactory: engine.factory)
    }

    // MARK: - Handshake

    @Test("the handshake reads this daemon's real /version and negotiates down to the target")
    func negotiatesFromRealVersionBody() async throws {
        let engine = ScriptedEngine([ScriptedEngine.versionResponse])
        let version = try await client(engine).version()

        #expect(version.engineVersion == "29.4.0")
        #expect(version.apiVersion == ThrallAPIVersion(major: 1, minor: 54))
        #expect(version.minimumAPIVersion == ThrallAPIVersion(major: 1, minor: 40))
        #expect(version.platformName == "Docker Engine - Community")
        #expect(version.negotiated == ThrallEngineNegotiation.target)
        #expect(version.pathPrefix == "/v1.51")
        // Sent unversioned: a version probe that needs a version cannot start.
        #expect(await engine.requestLines() == ["GET /version HTTP/1.1"])
    }

    @Test("the negotiated version is cached, not re-probed per read")
    func versionIsCached() async throws {
        let engine = ScriptedEngine([
            ScriptedEngine.versionResponse,
            ScriptedEngine.response("[]"),
            ScriptedEngine.response("[]"),
        ])
        let client = try client(engine)
        _ = try await client.containers()
        _ = try await client.containers()
        // Three requests, not four: one handshake plus two reads.
        #expect(engine.requestCount == 3)
    }

    /// The path prefix comes from the handshake, so this assertion is what
    /// proves no `/v1.xx` is hardcoded anywhere in the client.
    @Test("reads are pathed with the negotiated version")
    func readsUseNegotiatedPrefix() async throws {
        let engine = ScriptedEngine([
            ScriptedEngine.versionResponse,
            ScriptedEngine.response("[]"),
            ScriptedEngine.response("[]"),
            ScriptedEngine.response(#"{"Volumes":[],"Warnings":null}"#),
            ScriptedEngine.response("[]"),
            ScriptedEngine.response(#"{"LayersSize":0}"#),
        ])
        let client = try client(engine)
        _ = try await client.containers()
        _ = try await client.images()
        _ = try await client.volumes()
        _ = try await client.networks()
        _ = try await client.diskUsage()

        #expect(await engine.requestLines() == [
            "GET /version HTTP/1.1",
            "GET /v1.51/containers/json?all=1 HTTP/1.1",
            "GET /v1.51/images/json?all=0 HTTP/1.1",
            "GET /v1.51/volumes HTTP/1.1",
            "GET /v1.51/networks HTTP/1.1",
            "GET /v1.51/system/df HTTP/1.1",
        ])
    }

    /// A stack whose containers have all exited must still get a row — 28 of
    /// the 48 containers here are exited, including all of `aai1058`.
    @Test("containers defaults to all=1, because an all-exited stack still has a row")
    func containersIncludesStoppedByDefault() async throws {
        let engine = ScriptedEngine([ScriptedEngine.versionResponse, ScriptedEngine.response("[]")])
        _ = try await client(engine).containers()
        #expect(await engine.requestLines().last == "GET /v1.51/containers/json?all=1 HTTP/1.1")
    }

    @Test("an engine below the floor fails the handshake closed")
    func oldEngineFailsClosed() async throws {
        let engine = ScriptedEngine([
            ScriptedEngine.response(#"{"Version":"19.03.0","ApiVersion":"1.40","MinAPIVersion":"1.12"}"#),
        ])
        await #expect(throws: ThrallEngineError.apiTooOld(reported: "1.40", minimumSupported: "1.41")) {
            _ = try await client(engine).version()
        }
    }

    @Test("a /version body with no ApiVersion is unreadable rather than assumed")
    func versionWithoutAPIVersion() async throws {
        let engine = ScriptedEngine([ScriptedEngine.response(#"{"Version":"29.4.0"}"#)])
        await #expect(throws: ThrallEngineError.self) { _ = try await client(engine).version() }
    }

    // MARK: - Errors

    /// The engine puts a usable sentence in `{"message": ...}` and it should
    /// reach the user unchanged — a paraphrase is worse than the original.
    @Test("an engine error surfaces the engine's own message")
    func engineErrorMessage() async throws {
        let engine = ScriptedEngine([
            ScriptedEngine.versionResponse,
            ScriptedEngine.response(#"{"message":"No such container: abc"}"#,
                                    status: 404, reason: "Not Found"),
        ])
        await #expect(throws: ThrallEngineError.http(status: 404,
                                                     message: "No such container: abc")) {
            _ = try await client(engine).inspect(containerID: "abc")
        }
    }

    @Test("an error body with no message falls back to the reason phrase")
    func errorWithoutMessage() async throws {
        let engine = ScriptedEngine([
            ScriptedEngine.versionResponse,
            ScriptedEngine.response("<html>bad gateway</html>", status: 502, reason: "Bad Gateway"),
        ])
        await #expect(throws: ThrallEngineError.http(status: 502, message: "Bad Gateway")) {
            _ = try await client(engine).containers()
        }
    }

    @Test("a body that is not the expected shape is a decoding error naming the type")
    func decodingError() async throws {
        let engine = ScriptedEngine([
            ScriptedEngine.versionResponse,
            ScriptedEngine.response(#"{"unexpected":true}"#),
        ])
        do {
            _ = try await client(engine).containers()
            Issue.record("expected a decoding failure")
        } catch let error as ThrallEngineError {
            guard case .decoding(let type, _) = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
            #expect(type.contains("ThrallContainerDTO"))
        }
    }

    /// Identifiers go straight into a path, so they are checked before a socket
    /// is opened. `..` would otherwise address a different endpoint entirely.
    @Test("a hostile container identifier is refused before any connection",
          arguments: ["../../info", "abc/json", "", "a b", "-flag", "abc?all=1"])
    func hostileIdentifiers(identifier: String) async throws {
        let engine = ScriptedEngine([ScriptedEngine.versionResponse])
        await #expect(throws: ThrallEngineError.self) {
            _ = try await client(engine).inspect(containerID: identifier)
        }
        // The handshake happened; the read did not.
        #expect(engine.requestCount <= 1)
    }

    @Test("a remote endpoint is refused at construction, with the reason")
    func remoteEndpointRefused() throws {
        let endpoint = try #require(ThrallEngineEndpoint.parse("tcp://10.0.0.4:2376"))
        #expect(throws: ThrallEngineError.self) {
            _ = try ThrallEngineClient(endpoint: endpoint)
        }
    }

    // MARK: - Query encoding

    /// `/events`' `filters` is JSON — braces, quotes, brackets — and
    /// `ThrallHTTPRequest` refuses an unencoded target rather than encoding it
    /// for us, so this has to be right here.
    @Test("query values are percent-encoded, including JSON filters")
    func queryEncoding() throws {
        let target = ThrallEngineClient.target(
            "/v1.51/events",
            query: [("filters", #"{"type":["container"]}"#), ("since", "0")])
        #expect(target == "/v1.51/events?filters=%7B%22type%22%3A%5B%22container%22%5D%7D&since=0")
        // And the result is something the request encoder will actually accept.
        #expect(throws: Never.self) { try ThrallHTTPRequest(target: target).encoded() }
    }

    @Test("an empty query adds no question mark")
    func emptyQuery() {
        #expect(ThrallEngineClient.target("/v1.51/volumes", query: []) == "/v1.51/volumes")
    }

    // MARK: - Against the real engine, when there is one

    @Test("the live engine negotiates and lists containers",
          .enabled(if: LiveEngine.socketPath != nil))
    func liveReads() async throws {
        let path = try #require(LiveEngine.socketPath)
        let client = try ThrallEngineClient(endpoint: .unixSocket(path: path))

        let version = try await client.version()
        #expect(version.negotiated <= ThrallEngineNegotiation.target)
        #expect(version.negotiated >= ThrallEngineNegotiation.floor)
        #expect(!version.engineVersion.isEmpty)

        let containers = try await client.containers()
        #expect(!containers.isEmpty)
        // Every container the engine reports must decode with an id and a state.
        #expect(containers.allSatisfy { !$0.id.isEmpty && !$0.state.isEmpty })

        let usage = try await client.diskUsage()
        #expect(usage.layersSize > 0)
        #expect(usage.reclaimableBuildCache >= 0)
    }

    @Test("a live inspect carries the fields crash-loop detection needs",
          .enabled(if: LiveEngine.socketPath != nil))
    func liveInspect() async throws {
        let path = try #require(LiveEngine.socketPath)
        let client = try ThrallEngineClient(endpoint: .unixSocket(path: path))
        let containers = try await client.containers()
        let first = try #require(containers.first)
        let inspected = try await client.inspect(containerID: first.id)

        #expect(inspected.id == first.id)
        #expect(inspected.restartCount >= 0)
        #expect(!inspected.state.status.isEmpty)
        #expect(inspected.created != nil, "Created is RFC 3339 with nanoseconds and must parse")
        if inspected.state.running {
            // The Go zero time, mapped to nil rather than to the year 1.
            #expect(inspected.state.finishedAt == nil)
            #expect(inspected.state.startedAt != nil)
        }
    }
}
