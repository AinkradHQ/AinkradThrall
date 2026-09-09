import Foundation
@testable import ThrallFeature

/// Hands `ThrallEngineClient` a fresh scripted stream per request and keeps
/// each one, so a test can assert on the target that went out as well as on
/// what came back. The client opens one connection per request, so "how many
/// streams were created" is also "how many requests were made" — which is how
/// the version cache is tested.
final class ScriptedEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Data]
    private var streams: [ScriptedByteStream] = []

    init(_ responses: [Data]) {
        self.queued = responses
    }

    var factory: ThrallEngineClient.StreamFactory {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            // An exhausted script becomes a peer that closes without speaking,
            // which is what an engine restart looks like.
            let response = queued.isEmpty ? Data() : queued.removeFirst()
            // Split small on purpose: every engine read goes through the same
            // boundary handling the parser tests fuzz.
            let stream = ScriptedByteStream.splitting(response, every: 64)
            streams.append(stream)
            return stream
        }
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streams.count
    }

    /// Snapshotted synchronously: `NSLock.lock()` is unavailable from an
    /// async context, so the lock is taken and released entirely inside this
    /// non-async call.
    private func snapshotStreams() -> [ScriptedByteStream] {
        lock.lock()
        defer { lock.unlock() }
        return streams
    }

    /// The request lines sent, in order.
    func requestLines() async -> [String] {
        var lines: [String] = []
        for stream in snapshotStreams() {
            let text = String(decoding: await stream.written, as: UTF8.self)
            lines.append(text.components(separatedBy: "\r\n").first ?? "")
        }
        return lines
    }

    /// A `Content-Length` response, which is what the engine uses for small
    /// bodies. The chunked path is covered exhaustively in the parser tests.
    static func response(_ json: String, status: Int = 200, reason: String = "OK") -> Data {
        let body = Data(json.utf8)
        let head = """
            HTTP/1.1 \(status) \(reason)\r
            Api-Version: 1.54\r
            Connection: close\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            \r

            """
        return Data(head.utf8) + body
    }

    /// This daemon's real `/version` body, trimmed of its `Components` array.
    static let versionBody = """
        {"Platform":{"Name":"Docker Engine - Community"},"Version":"29.4.0",\
        "ApiVersion":"1.54","MinAPIVersion":"1.40","Os":"linux","Arch":"arm64",\
        "GitCommit":"daa0cb7f","GoVersion":"go1.26.1","Experimental":true}
        """

    static var versionResponse: Data { response(versionBody) }
}
