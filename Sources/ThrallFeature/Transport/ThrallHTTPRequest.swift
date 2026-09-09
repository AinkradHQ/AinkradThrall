import Foundation

/// One HTTP/1.1 request, encoded to bytes. Pure — it never touches a socket,
/// so every validation rule below is testable without a daemon.
///
/// **`Connection: close` is not negotiable.** Thrall opens one connection per
/// request and never pools, because a pooled connection reused after a hijack
/// (`POST /containers/{id}/attach`, `/exec/{id}/start`) would parse the
/// *container's* first line of output as an HTTP status line. That failure is
/// intermittent, looks like corruption rather than a bug, and is avoided
/// entirely by not having a pool. See `ThrallHijackedStream`.
///
/// **`Host` is required even over AF_UNIX.** There is no host in a unix socket
/// address, but HTTP/1.1 mandates the field (RFC 9112 3.2) and the Docker
/// engine's mux rejects a request without one. The value is arbitrary.
public struct ThrallHTTPRequest: Equatable, Sendable {
    public var method: String
    /// Request target, **already percent-encoded**, including any query.
    /// Encoding is the caller's job because only the caller knows which parts
    /// are data: a container name may legally contain a `.` and an image
    /// reference a `/`, and a helpful re-encode here would corrupt both.
    public var target: String
    public var headers: [(name: String, value: String)]
    public var body: Data?

    public init(method: String = "GET",
                target: String,
                headers: [(name: String, value: String)] = [],
                body: Data? = nil) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    /// Serialises to wire bytes, or throws `.invalidRequest`.
    ///
    /// The validation exists because the target is assembled from engine data
    /// — container IDs, image references, compose service names — and one
    /// unescaped CRLF in any of them would let a value smuggle a second
    /// request onto a socket that is root-equivalent on this machine. It is
    /// cheap, it is at the boundary, and it is the last place to catch it.
    public func encoded() throws -> Data {
        guard !method.isEmpty, method.allSatisfy(Self.isTokenCharacter) else {
            throw ThrallTransportError.invalidRequest("method is not an HTTP token: \(method)")
        }
        guard target.hasPrefix("/") else {
            throw ThrallTransportError.invalidRequest("target must be absolute-path form: \(target)")
        }
        guard target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            throw ThrallTransportError.invalidRequest(
                "target contains a space, a control character or a non-ASCII scalar; "
                    + "percent-encode it before it reaches here")
        }

        var lines = ["\(method) \(target) HTTP/1.1"]
        var seen = Set<String>()
        for field in headers {
            guard !field.name.isEmpty, field.name.allSatisfy(Self.isTokenCharacter) else {
                throw ThrallTransportError.invalidRequest("header name is not a token: \(field.name)")
            }
            // Checked on **unicode scalars**, not characters. Swift treats
            // "\r\n" as a single grapheme cluster, so a per-`Character`
            // comparison against "\r" and "\n" matches neither and lets the
            // one sequence that actually smuggles a request straight through.
            // Found by the test below, which passed against the character
            // version for the wrong reason.
            guard field.value.unicodeScalars.allSatisfy(Self.isFieldValueScalar) else {
                throw ThrallTransportError.invalidRequest(
                    "header \(field.name) value contains a control character")
            }
            seen.insert(field.name.lowercased())
            lines.append("\(field.name): \(field.value)")
        }
        // Defaults are appended only if the caller did not set them, so a test
        // (or a future streaming call that needs `Upgrade`) can override.
        if !seen.contains("host") { lines.append("Host: docker") }
        if !seen.contains("connection") { lines.append("Connection: close") }
        // Docker honours gzip if offered, and a compressed body would need a
        // decoder this transport does not have. Refuse it on the way out
        // rather than discovering it in the response.
        if !seen.contains("accept-encoding") { lines.append("Accept-Encoding: identity") }
        if let body, !seen.contains("content-length") {
            lines.append("Content-Length: \(body.count)")
        }

        var out = Data(lines.joined(separator: "\r\n").utf8)
        out.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A])
        if let body { out.append(body) }
        return out
    }

    /// RFC 9110 5.5 `field-value`: printable ASCII, plus SP and HTAB, plus
    /// obs-text. Every other control character is refused — CR and LF because
    /// they end a field, and the rest because a header carrying one is not
    /// something the engine sent us to echo back.
    private static func isFieldValueScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 { return true }
        if value >= 0x20 && value != 0x7F { return true }
        return false
    }

    /// RFC 9110 5.6.2 `tchar`.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        if (ascii >= 0x30 && ascii <= 0x39) || (ascii >= 0x41 && ascii <= 0x5A)
            || (ascii >= 0x61 && ascii <= 0x7A) { return true }
        return "!#$%&'*+-.^_`|~".utf8.contains(ascii)
    }

    public static func == (lhs: ThrallHTTPRequest, rhs: ThrallHTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target && lhs.body == rhs.body
            && lhs.headers.count == rhs.headers.count
            && zip(lhs.headers, rhs.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}
