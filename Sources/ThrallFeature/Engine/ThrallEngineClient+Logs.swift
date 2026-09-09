import Foundation

extension ThrallEngineClient {
    /// Reads a bounded tail of one container's log.
    ///
    /// **The framing is chosen from the response's own `Content-Type`**, never
    /// from a pre-flight `inspect` of `Config.Tty` — that would be a second
    /// source of truth that can disagree with the response in hand if the
    /// container is recreated between the two calls. An unrecognised type
    /// fails closed rather than guessing, because demultiplexing a raw stream
    /// does not error, it renders garbage.
    ///
    /// Bounded on both axes. `tail` bounds what the engine sends; `maximumBytes`
    /// bounds what we keep, because a container that logs a megabyte per second
    /// exists and 24 of them are normal here.
    public func logs(containerID: String,
                     tail: Int = 200,
                     includeStdout: Bool = true,
                     includeStderr: Bool = true,
                     maximumBytes: Int = 256 * 1024) async throws -> [ThrallLogFrame] {
        let prefix = try await version().pathPrefix
        let identifier = try Self.identifier(containerID)
        let target = Self.target(prefix + "/containers/\(identifier)/logs",
                                 query: [("stdout", includeStdout ? "1" : "0"),
                                         ("stderr", includeStderr ? "1" : "0"),
                                         ("tail", String(max(1, min(tail, 10_000)))),
                                         ("timestamps", "0")])
        let stream = makeStream()
        let reader = ThrallHTTPResponseReader(stream: stream)
        try await stream.connect()
        try await stream.send(ThrallHTTPRequest(target: target).encoded())

        var decoder: ThrallLogFrameDecoder?
        var frames: [ThrallLogFrame] = []
        var kept = 0

        while let event = try await reader.next(timeout: requestTimeout) {
            switch event {
            case .head(let head):
                guard head.isSuccess else {
                    throw ThrallEngineError.http(status: head.statusCode,
                                                 message: head.reasonPhrase)
                }
                guard let framing = ThrallLogFrameDecoder
                    .framing(forContentType: head.contentType) else {
                    throw ThrallTransportError.unsupportedFraming(
                        "log Content-Type \(head.contentType ?? "absent") is not one Thrall reads")
                }
                decoder = ThrallLogFrameDecoder(framing: framing)
            case .body(let chunk):
                guard decoder != nil else {
                    throw ThrallTransportError.malformedResponse("log body before the head")
                }
                for frame in try decoder!.feed(chunk) {
                    kept += frame.payload.count
                    guard kept <= maximumBytes else { return frames }
                    frames.append(frame)
                }
            case .end, .trailers:
                break
            case .upgraded:
                throw ThrallTransportError.unsupportedFraming(
                    "a log read must not upgrade the connection")
            }
        }
        await stream.close()
        return frames
    }

    /// The tail as text, which is what fingerprinting needs.
    ///
    /// **stderr only by default.** A dying process writes its reason to
    /// stderr, and interleaving a service's ordinary stdout chatter into the
    /// fingerprint is what makes two containers with the same cause look
    /// different.
    public func logTail(containerID: String,
                        lines: Int = 40,
                        stderrOnly: Bool = true) async throws -> String {
        let frames = try await logs(containerID: containerID, tail: lines,
                                    includeStdout: !stderrOnly, includeStderr: true)
        let wanted = stderrOnly
            ? frames.filter { $0.stream == .stderr }
            : frames
        // Falls back to everything when stderr was empty: a process that logs
        // its fatal error to stdout is common enough that returning nothing
        // would lose the evidence.
        let source = wanted.isEmpty ? frames : wanted
        return source.reduce(into: Data()) { $0.append($1.payload) }
            .withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }
}
