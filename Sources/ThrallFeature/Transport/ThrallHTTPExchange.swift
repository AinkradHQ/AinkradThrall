import Foundation

/// A complete unary response.
public struct ThrallHTTPResponse: Sendable {
    public let head: ThrallHTTPResponseHead
    public let body: Data
    public let trailers: ThrallHTTPHeaders?
}

/// Pulls framing events off a byte stream, one at a time.
///
/// The single driver for both shapes of Docker call, which is the point: a
/// unary `GET /containers/json` and a `follow` log stream differ only in the
/// timeout they pass and in whether they accumulate the body. Two drivers
/// would mean two chances to get the dechunker's mid-chunk emission wrong.
public actor ThrallHTTPResponseReader {
    private let stream: any ThrallByteStream
    private var parser: ThrallHTTPResponseParser
    private var queued: [ThrallHTTPResponseParser.Output] = []
    private var isDone = false

    public init(stream: any ThrallByteStream,
                limits: ThrallHTTPResponseParser.Limits = .default) {
        self.stream = stream
        self.parser = ThrallHTTPResponseParser(limits: limits)
    }

    /// The next framing event, reading from the socket only when the parser
    /// has nothing buffered. Returns nil once the message has ended.
    ///
    /// Pass `nil` for `timeout` on `/events` and on a `follow` log stream —
    /// both are legitimately silent for minutes, and a timeout there reads to
    /// the user as the engine dying.
    public func next(timeout: Duration?) async throws -> ThrallHTTPResponseParser.Output? {
        while true {
            if !queued.isEmpty { return queued.removeFirst() }
            if isDone { return nil }
            do {
                let bytes = try await stream.read(timeout: timeout)
                queued = try parser.feed(bytes)
            } catch ThrallTransportError.closed {
                // End of connection. For a `Connection: close` response with no
                // declared length this is the legitimate terminator, so the
                // parser decides whether it is `.end` or a truncation.
                queued = try parser.finish()
                isDone = true
            }
            if parser.isFinished { isDone = true }
        }
    }
}

/// The join: request out, response in. Kept separate from the engine client so
/// that layer never assembles a byte.
public enum ThrallHTTPExchange {
    /// Sends `request` and reads the whole response.
    ///
    /// Only for endpoints with a bounded body. `/events` and a `follow` log
    /// stream never complete, so calling this on one would accumulate until
    /// `maximumBodyLength` — use `ThrallHTTPResponseReader` directly for
    /// those.
    public static func perform(
        _ request: ThrallHTTPRequest,
        over stream: any ThrallByteStream,
        timeout: Duration = .seconds(30),
        maximumBodyLength: Int = 64 * 1024 * 1024
    ) async throws -> ThrallHTTPResponse {
        try await stream.connect()
        try await stream.send(request.encoded())

        let reader = ThrallHTTPResponseReader(stream: stream)
        var head: ThrallHTTPResponseHead?
        var body = Data()
        var trailers: ThrallHTTPHeaders?

        while let event = try await reader.next(timeout: timeout) {
            switch event {
            case .head(let value):
                head = value
            case .body(let chunk):
                guard body.count + chunk.count <= maximumBodyLength else {
                    throw ThrallTransportError.tooLarge(
                        "response body exceeded \(maximumBodyLength) bytes")
                }
                body.append(chunk)
            case .trailers(let value):
                trailers = value
            case .end:
                break
            case .upgraded:
                // A unary caller has nowhere to put a hijacked pipe, and
                // returning the head alone would leak the socket while looking
                // like success.
                throw ThrallTransportError.unsupportedFraming(
                    "the engine upgraded the connection; use ThrallHijackedStream")
            }
        }
        guard let head else {
            throw ThrallTransportError.malformedResponse("no response head was read")
        }
        return ThrallHTTPResponse(head: head, body: body, trailers: trailers)
    }
}
