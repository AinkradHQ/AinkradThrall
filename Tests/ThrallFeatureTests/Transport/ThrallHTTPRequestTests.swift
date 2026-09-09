import Foundation
import Testing
@testable import ThrallFeature

/// The request encoder is the last place a container name, image reference or
/// compose service name can be caught before it reaches a socket that is
/// root-equivalent on this machine.
@Suite("ThrallHTTPRequest")
struct ThrallHTTPRequestTests {
    private func lines(_ request: ThrallHTTPRequest) throws -> [String] {
        let encoded = try request.encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n")[0]
        return head.components(separatedBy: "\r\n")
    }

    @Test("a plain GET carries the defaults the engine needs")
    func defaults() throws {
        let encoded = try ThrallHTTPRequest(target: "/v1.51/containers/json?all=1").encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.hasPrefix("GET /v1.51/containers/json?all=1 HTTP/1.1\r\n"))
        // `Host` is mandatory in HTTP/1.1 and the engine's mux rejects a
        // request without one, even though AF_UNIX has no host.
        #expect(text.contains("\r\nHost: docker\r\n"))
        // No pooling, so no keep-alive — see ThrallHTTPRequest's header note.
        #expect(text.contains("\r\nConnection: close\r\n"))
        // Docker will gzip if offered and this transport has no decompressor.
        #expect(text.contains("\r\nAccept-Encoding: identity\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test("a body sets Content-Length and is appended after the blank line")
    func bodyLength() throws {
        let body = Data(#"{"Force":true}"#.utf8)
        let request = ThrallHTTPRequest(method: "POST",
                                        target: "/v1.51/containers/abc/stop",
                                        headers: [(name: "Content-Type", value: "application/json")],
                                        body: body)
        let encoded = try request.encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("\r\nContent-Length: \(body.count)\r\n"))
        #expect(text.hasSuffix("\r\n\r\n" + #"{"Force":true}"#))
    }

    @Test("a caller-set default is not duplicated")
    func callerOverridesDefault() throws {
        let request = ThrallHTTPRequest(target: "/v1.51/version",
                                        headers: [(name: "Host", value: "localhost")])
        let fields = try lines(request)
        #expect(fields.filter { $0.hasPrefix("Host:") } == ["Host: localhost"])
    }

    /// One unescaped CRLF in a container name would smuggle a second request
    /// onto the socket. Every one of these is data that arrives from the
    /// engine or from a compose file, not from a literal in our source.
    @Test("a target that could smuggle a request is refused", arguments: [
        "/v1.51/containers/abc\r\nX-Injected: 1/stop",
        "/v1.51/containers/ab c/stop",
        "/v1.51/containers/abc\n/stop",
        "/v1.51/containers/n\u{00E4}me/stop",
        "v1.51/version",
        "",
    ])
    func invalidTargets(target: String) {
        #expect(throws: ThrallTransportError.self) {
            try ThrallHTTPRequest(target: target).encoded()
        }
    }

    @Test("a method that is not a token is refused", arguments: ["GET ", "GE T", "", "GET\r\n"])
    func invalidMethods(method: String) {
        #expect(throws: ThrallTransportError.self) {
            try ThrallHTTPRequest(method: method, target: "/v1.51/version").encoded()
        }
    }

    @Test("a header value containing CR or LF is refused")
    func invalidHeaderValue() {
        let request = ThrallHTTPRequest(target: "/v1.51/version",
                                        headers: [(name: "X-Filter", value: "a\r\nX-Injected: 1")])
        #expect(throws: ThrallTransportError.self) { try request.encoded() }
    }

    @Test("a header name that is not a token is refused")
    func invalidHeaderName() {
        let request = ThrallHTTPRequest(target: "/v1.51/version",
                                        headers: [(name: "X Filter", value: "1")])
        #expect(throws: ThrallTransportError.self) { try request.encoded() }
    }

    /// Percent-encoded bytes must pass through untouched: a helpful re-encode
    /// here would corrupt an image reference's `/` or a filter's JSON.
    @Test("an already-encoded target is passed through byte for byte")
    func encodedTargetUntouched() throws {
        let target = "/v1.51/events?filters=%7B%22type%22%3A%5B%22container%22%5D%7D"
        let text = String(decoding: try ThrallHTTPRequest(target: target).encoded(), as: UTF8.self)
        #expect(text.hasPrefix("GET \(target) HTTP/1.1\r\n"))
    }
}
