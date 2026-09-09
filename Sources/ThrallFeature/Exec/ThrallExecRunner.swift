import Foundation

public struct ThrallExecResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int?
    public let truncated: Bool

    public var succeeded: Bool { exitCode == 0 }
}

public enum ThrallExecError: Error, Equatable, Sendable {
    case emptyCommand
    case invalidArgument(String)
    case tooManyArguments(Int)
    case engine(String)
}

/// Runs one non-interactive command inside a container.
///
/// ## No shell, no PTY, argv only
///
/// The command is an **argv array**, never a string handed to `sh -c`. A shell
/// string is an injection surface with no bottom: everything Thrall knows
/// about a container comes from the engine or a compose file, so a value that
/// reaches here can contain anything. argv removes the question entirely — and
/// it costs nothing, because the commands this exists for (`env`,
/// `cat /etc/hosts`, `nc -z db 5432`) are argv-shaped already. Those cover
/// roughly 80% of crash-loop triage; interactive work hands off to Rune.
///
/// ## The framing correction
///
/// **`/exec/{id}/start` reports `Content-Type:
/// application/vnd.docker.raw-stream` even when the body is multiplexed.**
/// Verified against this machine: an exec created with `Tty: false` answers
/// `200` with that raw-stream header and a body beginning
/// `01 00 00 00 00 00 01 b3` — an 8-byte multiplexed frame header.
///
/// So Task B's rule — "framing comes from the response `Content-Type` and
/// nothing else" — holds for `/containers/{id}/logs` (which really does say
/// `multiplexed-stream`) but **not here**. For exec, the authority is the
/// `Tty` value *we ourselves sent*, and that is safe precisely because we sent
/// it: the container-recreate race that made a pre-flight `inspect`
/// untrustworthy for logs cannot apply to a value from our own request body in
/// the same exchange. Thrall always sends `Tty: false`, so it always demuxes.
public struct ThrallExecRunner: Sendable {
    /// Enough for a diagnostic command; far short of anything that could be a
    /// script.
    public static let maximumArguments = 24
    public static let maximumOutputBytes = 256 * 1024

    private let client: ThrallEngineClient

    public init(client: ThrallEngineClient) {
        self.client = client
    }

    /// Splits a typed line into argv, honouring quotes but **never** shell
    /// metacharacters.
    ///
    /// `|`, `>`, `;`, `&` and `$(` are refused rather than passed through as
    /// literal arguments, because a user typing `cat x > y` expects a redirect
    /// and would otherwise get a file named `>` with no explanation. Refusing
    /// with a reason is honest; silently doing something else is not.
    public static func parse(commandLine: String) throws -> [String] {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ThrallExecError.emptyCommand }

        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var characters = Array(trimmed)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                // Inside quotes every one of these is literal data, and argv
                // passes it through unchanged — which is correct. Scanning the
                // whole line *before* parsing rejected `php -r "echo 1;"`,
                // which is a perfectly good command; the check has to know
                // about quoting.
                if character == open { quote = nil } else { current.append(character) }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index += 1
                continue
            }
            if let rejection = Self.shellRejection(at: index, in: characters) {
                throw ThrallExecError.invalidArgument(rejection)
            }
            if character.isWhitespace {
                if !current.isEmpty { arguments.append(current); current = "" }
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        guard quote == nil else {
            throw ThrallExecError.invalidArgument("unclosed quote")
        }
        if !current.isEmpty { arguments.append(current) }

        guard !arguments.isEmpty else { throw ThrallExecError.emptyCommand }
        guard arguments.count <= maximumArguments else {
            throw ThrallExecError.tooManyArguments(arguments.count)
        }
        for argument in arguments where argument.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F
        }) {
            throw ThrallExecError.invalidArgument("an argument contains a control character")
        }
        return arguments
    }

    /// The message for an unquoted shell construct, or nil.
    ///
    /// Every one of these is **refused with a reason rather than passed
    /// through as a literal**: a user typing `cat x > y` expects a redirect,
    /// and getting a file named `>` with no explanation is worse than being
    /// told no. `$` is included for the same reason — with no shell there is
    /// no expansion, so `echo $PATH` would print the four characters.
    static func shellRejection(at index: Int, in characters: [Character]) -> String? {
        let character = characters[index]
        let construct: String
        switch character {
        case "|", ">", "<", ";", "&", "`":
            construct = String(character)
        case "$":
            construct = "$"
        default:
            return nil
        }
        return "\(construct) needs a shell, and Thrall runs commands directly with no shell. "
            + "Quote it if you mean it literally, run the program itself, or use Rune for a "
            + "real terminal."
    }

    public func run(containerID: String, command: [String]) async throws -> ThrallExecResult {
        guard !command.isEmpty else { throw ThrallExecError.emptyCommand }
        guard command.count <= Self.maximumArguments else {
            throw ThrallExecError.tooManyArguments(command.count)
        }
        return try await client.exec(containerID: containerID,
                                     command: command,
                                     maximumBytes: Self.maximumOutputBytes)
    }
}

extension ThrallEngineClient {
    /// Creates and runs one exec, returning its output and exit code.
    func exec(containerID: String,
              command: [String],
              maximumBytes: Int) async throws -> ThrallExecResult {
        let prefix = try await version().pathPrefix
        let identifier = try Self.identifier(containerID)

        // Create. `Tty: false` is fixed, which is what makes the framing known.
        let createBody: [String: Any] = [
            "AttachStdout": true, "AttachStderr": true, "AttachStdin": false,
            "Tty": false, "Cmd": command,
        ]
        let created = try await postJSON(target: Self.target(
            prefix + "/containers/\(identifier)/exec", query: []), body: createBody)
        guard let execID = (try? JSONSerialization.jsonObject(with: created) as? [String: Any])?["Id"]
            as? String else {
            throw ThrallExecError.engine("the engine did not return an exec id")
        }

        // Start. The response hijacks the connection and runs to close.
        let stream = makeStream()
        try await stream.connect()
        let startBody = Data(#"{"Detach":false,"Tty":false}"#.utf8)
        try await stream.send(ThrallHTTPRequest(
            method: "POST",
            target: Self.target(prefix + "/exec/\(try Self.identifier(execID))/start", query: []),
            headers: [(name: "Content-Type", value: "application/json")],
            body: startBody).encoded())

        // Always multiplexed, because we sent `Tty: false` — see
        // `ThrallExecRunner`'s note on the raw-stream header.
        var decoder = ThrallLogFrameDecoder(framing: .multiplexed)
        let reader = ThrallHTTPResponseReader(stream: stream)
        var out = Data()
        var err = Data()
        var truncated = false

        loop: while let event = try await reader.next(timeout: .seconds(60)) {
            switch event {
            case .head(let head):
                guard head.isSuccess else {
                    throw ThrallExecError.engine("exec start returned \(head.statusCode)")
                }
            case .body(let chunk):
                for frame in try decoder.feed(chunk) {
                    if out.count + err.count + frame.payload.count > maximumBytes {
                        truncated = true
                        break loop
                    }
                    if frame.stream == .stderr { err.append(frame.payload) }
                    else { out.append(frame.payload) }
                }
            case .upgraded(let residual):
                // The other spelling of a hijack. The residual is already
                // output, which is exactly what `ThrallHijackedStream` exists
                // for.
                let hijacked = ThrallHijackedStream(upstream: stream, residual: residual)
                while true {
                    guard let chunk = try? await hijacked.read(timeout: .seconds(60)) else { break }
                    for frame in try decoder.feed(chunk) {
                        if out.count + err.count + frame.payload.count > maximumBytes {
                            truncated = true
                            break
                        }
                        if frame.stream == .stderr { err.append(frame.payload) }
                        else { out.append(frame.payload) }
                    }
                    if truncated { break }
                }
                break loop
            case .end, .trailers:
                break loop
            }
        }
        await stream.close()

        // Exit code comes from a separate inspect — the stream carries none.
        let inspected: [String: Any]? = try? await getJSONObject(
            target: Self.target(prefix + "/exec/\(try Self.identifier(execID))/json", query: []))
        return ThrallExecResult(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            exitCode: inspected?["ExitCode"] as? Int,
            truncated: truncated)
    }

    private func postJSON(target: String, body: [String: Any]) async throws -> Data {
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else {
            throw ThrallExecError.engine("could not encode the exec request")
        }
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(method: "POST", target: target,
                              headers: [(name: "Content-Type", value: "application/json")],
                              body: encoded),
            over: makeStream(),
            timeout: requestTimeout)
        guard response.head.isSuccess else {
            let message = (try? JSONDecoder().decode(ThrallEngineMessageDTO.self,
                                                     from: response.body))?.message
            throw ThrallExecError.engine(message ?? response.head.reasonPhrase)
        }
        return response.body
    }

    private func getJSONObject(target: String) async throws -> [String: Any]? {
        let response = try await ThrallHTTPExchange.perform(
            ThrallHTTPRequest(target: target), over: makeStream(), timeout: requestTimeout)
        return try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    }
}
