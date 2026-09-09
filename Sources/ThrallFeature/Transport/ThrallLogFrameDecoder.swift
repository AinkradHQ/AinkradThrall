import Foundation

/// Which of a container's streams a chunk of output came from.
public enum ThrallLogStream: UInt8, Equatable, Sendable, CaseIterable {
    case stdin = 0
    case stdout = 1
    case stderr = 2
}

/// One decoded piece of container output. Not a line — framing and line
/// splitting are separate concerns, and a frame may hold a partial line or
/// several.
public struct ThrallLogFrame: Equatable, Sendable {
    public let stream: ThrallLogStream
    public let payload: Data

    public init(stream: ThrallLogStream, payload: Data) {
        self.stream = stream
        self.payload = payload
    }
}

/// Decodes a container log or attach body into frames.
///
/// **The framing is chosen by the response's `Content-Type`, never by
/// inspecting the container first.** Docker uses one of two shapes for the
/// same endpoint:
///
///  * `application/vnd.docker.multiplexed-stream` — an 8-byte header per
///    frame, `[stream:UInt8][0,0,0][length:UInt32 big-endian]`. Verified on
///    this machine: `01 00 00 00 00 00 00 4f`, i.e. 79 bytes of stdout.
///  * `application/vnd.docker.raw-stream` — no framing at all. A container
///    started with a TTY merges stdout and stderr into the pty, so there is
///    nothing to demultiplex.
///
/// Demultiplexing a raw stream does not fail: it reads the container's own
/// first bytes as a frame header and renders garbage from then on. A
/// pre-flight `inspect` to read `Config.Tty` is not a fix either — it is a
/// second source of truth that can disagree with the response in hand (the
/// container can be recreated between the two calls). Hence: read the header,
/// and if it is not one of the two known types, refuse.
///
/// Desync is detected from the frame header's own redundancy — the three
/// padding bytes must be zero and the stream byte must be 0, 1 or 2 — so a
/// mis-selected framing throws within one frame instead of producing plausible
/// nonsense.
public struct ThrallLogFrameDecoder {
    public enum Framing: Equatable, Sendable {
        case multiplexed
        case raw
    }

    public static let multiplexedContentType = "application/vnd.docker.multiplexed-stream"
    public static let rawContentType = "application/vnd.docker.raw-stream"

    /// Maps a normalised `Content-Type` to a framing, or nil when it is not
    /// one this build can read. Nil is a hard stop at the call site — there is
    /// no sensible default.
    public static func framing(forContentType contentType: String?) -> Framing? {
        switch contentType {
        case multiplexedContentType: return .multiplexed
        case rawContentType: return .raw
        default: return nil
        }
    }

    private static let headerLength = 8

    public let framing: Framing
    /// Caps a declared frame length. A desynced header reads as a plausible
    /// hex number in the hundreds of megabytes; the cap turns that into an
    /// error instead of an allocation.
    public let maximumFrameLength: Int
    private var carry = Data()

    public init(framing: Framing, maximumFrameLength: Int = 16 * 1024 * 1024) {
        self.framing = framing
        self.maximumFrameLength = maximumFrameLength
    }

    /// Decodes whatever the new bytes completed. A frame split across reads
    /// stays in the carry buffer until it is whole — which happens constantly,
    /// because the dechunker above emits on chunk arrival and a frame has no
    /// reason to align to a chunk.
    public mutating func feed(_ bytes: Data) throws -> [ThrallLogFrame] {
        guard !bytes.isEmpty else { return [] }
        if framing == .raw {
            // A TTY container's output is already the thing the caller wants.
            // Attributed to stdout because the pty genuinely merged the two;
            // claiming otherwise would let a UI colour half of it wrongly.
            return [ThrallLogFrame(stream: .stdout, payload: bytes)]
        }

        carry.append(bytes)
        var frames: [ThrallLogFrame] = []
        var offset = carry.startIndex
        while carry.endIndex - offset >= Self.headerLength {
            let streamByte = carry[offset]
            guard let stream = ThrallLogStream(rawValue: streamByte) else {
                throw ThrallTransportError.malformedResponse(
                    "log frame stream byte \(streamByte) is not 0, 1 or 2 — "
                        + "the stream is desynced or is not multiplexed")
            }
            guard carry[offset + 1] == 0, carry[offset + 2] == 0, carry[offset + 3] == 0 else {
                throw ThrallTransportError.malformedResponse(
                    "log frame padding is non-zero — the stream is desynced or is not multiplexed")
            }
            var length = 0
            for index in 4..<8 {
                length = (length << 8) | Int(carry[offset + index])
            }
            guard length <= maximumFrameLength else {
                throw ThrallTransportError.tooLarge(
                    "log frame declares \(length) bytes, over the \(maximumFrameLength) cap")
            }
            let payloadStart = offset + Self.headerLength
            guard carry.endIndex - payloadStart >= length else { break }
            if length > 0 {
                frames.append(ThrallLogFrame(stream: stream,
                                             payload: Data(carry[payloadStart..<(payloadStart + length)])))
            }
            offset = payloadStart + length
        }
        carry = offset == carry.endIndex ? Data() : Data(carry[offset...])
        return frames
    }

    /// Bytes left over when the stream ended: a truncated frame. Returned
    /// rather than emitted, because a partial frame's payload length is
    /// unknown and guessing it would put a fragment of the next frame's header
    /// on screen.
    public mutating func finish() -> Data {
        let remainder = carry
        carry = Data()
        return remainder
    }
}
