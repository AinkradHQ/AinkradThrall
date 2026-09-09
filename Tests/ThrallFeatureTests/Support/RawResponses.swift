import Foundation

/// Wire bytes for the responses this transport has to read.
///
/// The header blocks are **verbatim from this machine's OrbStack socket**
/// (Docker 29.4.0, API 1.54), captured with `nc -U` so the framing survived —
/// `curl` de-chunks and would have hidden the whole problem. Bodies are
/// trimmed; framing is not.
///
/// Every declared length is **computed, never typed**. A hand-written
/// `Content-Length` or chunk size that drifts from its body turns a real
/// failure into a green test asserting the wrong framing, which is the one way
/// a fixture can be worse than no fixture.
enum RawResponses {
    static func bytes(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Content-Length

    static let versionBodyText = #"{"ApiVersion":"1.54","MinAPIVersion":"1.40"}"#
    static var versionBody: Data { bytes(versionBodyText) }

    /// `GET /version` — one of the few endpoints that declares a length.
    static var versionContentLength: Data {
        let head = """
            HTTP/1.1 200 OK\r
            Api-Version: 1.54\r
            Connection: close\r
            Content-Length: \(versionBody.count)\r
            Content-Type: application/json\r
            Date: Wed, 09 Sep 2026 11:53:39 GMT\r
            Docker-Experimental: true\r
            Ostype: linux\r
            Server: Docker/29.4.0 (linux)\r
            \r

            """
        return bytes(head) + versionBody
    }

    // MARK: - Chunked

    static let containersChunkOne = #"[{"Id":"f4b70cccfc26","State":"running"},"#
    static let containersChunkTwo = "{\"Id\":\"aec9af6e53\",\"State\":\"exited\"}]\n"
    static var containersBody: Data { bytes(containersChunkOne + containersChunkTwo) }

    static let chunkedHead = """
        HTTP/1.1 200 OK\r
        Api-Version: 1.54\r
        Connection: close\r
        Content-Type: application/json\r
        Date: Wed, 09 Sep 2026 11:53:47 GMT\r
        Docker-Experimental: true\r
        Ostype: linux\r
        Server: Docker/29.4.0 (linux)\r
        Transfer-Encoding: chunked\r
        \r

        """

    /// One chunk, size written in lowercase hex as the engine writes it
    /// (`4000`), with optional extensions the parser must ignore.
    static func chunk(_ text: String, extensions: String = "") -> Data {
        let size = Data(text.utf8).count
        return bytes(String(size, radix: 16) + extensions + "\r\n" + text + "\r\n")
    }

    static let lastChunk = bytes("0\r\n\r\n")

    /// `GET /containers/json` — the primary endpoint, and it is **chunked**.
    /// Two chunks, so a consumer that treats one chunk as the whole body fails.
    static var containersChunked: Data {
        bytes(chunkedHead) + chunk(containersChunkOne) + chunk(containersChunkTwo) + lastChunk
    }

    /// The engine's answer to a mis-typed path: a redirect with a zero-length
    /// body. It must complete rather than sit waiting for bytes.
    static var redirectEmptyBody: Data {
        bytes("""
            HTTP/1.1 301 Moved Permanently\r
            Connection: close\r
            Content-Length: 0\r
            Date: Wed, 09 Sep 2026 11:53:56 GMT\r
            Location: /v1.51/containers/logs\r
            \r

            """)
    }

    // MARK: - Log streams

    static let multiplexedHead = """
        HTTP/1.1 200 OK\r
        Api-Version: 1.54\r
        Connection: close\r
        Content-Type: application/vnd.docker.multiplexed-stream\r
        Date: Wed, 09 Sep 2026 11:54:03 GMT\r
        Server: Docker/29.4.0 (linux)\r
        Transfer-Encoding: chunked\r
        \r

        """

    /// Chunked on the outside, multiplexed on the inside — both layers at
    /// once, which is the real arrangement.
    static func multiplexedLogResponse(frames: [Data]) -> Data {
        let payload = frames.reduce(into: Data()) { $0.append($1) }
        var out = bytes(multiplexedHead)
        out.append(bytes(String(payload.count, radix: 16) + "\r\n"))
        out.append(payload)
        out.append(bytes("\r\n"))
        out.append(lastChunk)
        return out
    }

    /// A multiplexed frame: `[stream][0,0,0][length big-endian]` then payload.
    /// Verified on the wire as `01 00 00 00 00 00 00 4f`.
    static func logFrame(stream: UInt8, payload: Data) -> Data {
        var out = Data([stream, 0, 0, 0])
        let length = UInt32(payload.count)
        out.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
        out.append(payload)
        return out
    }

    // MARK: - Events

    /// One `/events` record, with the label set **copied from a real
    /// container on this machine** rather than invented.
    ///
    /// Two things it preserves that a made-up fixture loses:
    ///
    ///  * **Size.** Measured across all 48 containers here, the equivalent
    ///    event payload runs 346–1945 bytes with a median of 1371, and 44 of
    ///    48 exceed a kilobyte. So one event is routinely larger than the
    ///    reads it arrives in, and the splitter above the dechunker is not
    ///    optional.
    ///  * **`config_files` is a comma-separated LIST.** This container
    ///    declares two (`docker-compose.yml,docker-compose.dev.yml`). Task D's
    ///    indexer seeds from this label, and treating it as a single path
    ///    would produce a config file that does not exist.
    static func eventLine(action: String, container: String) -> String {
        let worktree = "/private/tmp/claude-501/-Users-ahmedmelhalaby-Home-Projects-AutomotiveAi"
            + "/0ab18311-2c30-4dcd-a4da-4d1f9b3535e7/scratchpad/wt-1058"
        return """
        {"status":"\(action)","id":"\(container)","Type":"container","Action":"\(action)",\
        "Actor":{"ID":"\(container)","Attributes":{\
        "com.docker.compose.config-hash":\
        "d4901ca3b16d5315557af06063e81bee651b2eb9f01a1d8abc92354256223b13",\
        "com.docker.compose.container-number":"1","com.docker.compose.depends_on":"",\
        "com.docker.compose.image":\
        "sha256:64bc52bbd293bac7a0e8e1eb653a6ed5020f06bc1ddba49e54f245f487599a52",\
        "com.docker.compose.oneoff":"False","com.docker.compose.project":"aai1058",\
        "com.docker.compose.project.config_files":\
        "\(worktree)/docker-compose.yml,\(worktree)/docker-compose.dev.yml",\
        "com.docker.compose.project.working_dir":"\(worktree)",\
        "com.docker.compose.service":"mailpit","com.docker.compose.version":"5.1.2",\
        "org.opencontainers.image.description":\
        "An email and SMTP testing tool with API for developers",\
        "org.opencontainers.image.documentation":"https://mailpit.axllent.org/docs/",\
        "org.opencontainers.image.licenses":"MIT",\
        "org.opencontainers.image.source":"https://github.com/axllent/mailpit",\
        "org.opencontainers.image.title":"Mailpit",\
        "org.opencontainers.image.url":"https://mailpit.axllent.org",\
        "exitCode":"1","image":"axllent/mailpit:latest","name":"aai1058-mailpit-1"}},\
        "scope":"local","time":1789041600,"timeNano":1789041600123456789}
        """
    }
}
