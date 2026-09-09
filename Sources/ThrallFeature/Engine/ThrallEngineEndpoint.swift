import Foundation

/// Where an engine lives.
///
/// `unsupported` is a case rather than a parse failure on purpose. With three
/// contexts configured on this machine, a context Thrall cannot drive still has
/// to appear in the switcher — silently hiding it would leave the user
/// wondering why `desktop-linux` vanished, and "is this the container I think
/// it is" is the failure mode the switcher exists to prevent.
public enum ThrallEngineEndpoint: Equatable, Hashable, Sendable {
    case unixSocket(path: String)
    case unsupported(scheme: String, detail: String, reason: String)

    public var isSupported: Bool {
        if case .unixSocket = self { return true }
        return false
    }

    /// How to describe this endpoint in the UI.
    public var displayString: String {
        switch self {
        case .unixSocket(let path): return path
        case .unsupported(let scheme, let detail, _): return "\(scheme)://\(detail)"
        }
    }

    /// Identity of the **engine** behind this endpoint, with symlinks resolved.
    ///
    /// Two contexts can name the same daemon by different paths, and on this
    /// machine two of them do: `/var/run/docker.sock` is a symlink to
    /// `~/.orbstack/run/docker.sock`, so the implicit `default` context and
    /// `orbstack` are one engine wearing two names. Keying anything on the
    /// literal path would show them as two, and a stack seen through both
    /// would duplicate.
    ///
    /// Resolution needs the file to exist; for a socket that is absent (a
    /// stopped Docker Desktop, say) this falls back to the standardized path,
    /// which is the best available answer and never wrong in a way that merges
    /// two live engines.
    public var engineKey: String {
        switch self {
        case .unixSocket(let path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return "unix:" + url.resolvingSymlinksInPath().standardizedFileURL.path
        case .unsupported(let scheme, let detail, _):
            return "\(scheme):\(detail)"
        }
    }

    /// Parses a `DOCKER_HOST`-style value.
    ///
    /// Returns nil only for input that names nothing at all. Anything that
    /// names a transport Thrall will not drive comes back as `.unsupported`
    /// with the reason, so it can be listed and explained rather than dropped.
    public static func parse(_ raw: String) -> ThrallEngineEndpoint? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let separator = text.range(of: "://") {
            let scheme = String(text[text.startIndex..<separator.lowerBound]).lowercased()
            let detail = String(text[separator.upperBound...])
            switch scheme {
            case "unix":
                // `unix:///var/run/docker.sock` — three slashes, so `detail`
                // is already the absolute path.
                guard detail.hasPrefix("/") else { return nil }
                return .unixSocket(path: detail)
            case "tcp", "http", "https":
                // **Refused in v1, deliberately.** Client certificates from
                // `~/.docker/*.pem` would need a Keychain side effect a
                // container manager has no business performing, and the
                // half-done alternative — honouring `SkipTLSVerify` — accepts
                // an unverified chain on a socket that is root-equivalent to
                // whatever is on the far end.
                return .unsupported(scheme: scheme, detail: detail,
                                    reason: "remote engines over TLS are not supported yet")
            case "ssh":
                return .unsupported(scheme: scheme, detail: detail,
                                    reason: "SSH-tunnelled engines are not supported yet")
            case "npipe":
                return .unsupported(scheme: scheme, detail: detail,
                                    reason: "named pipes are Windows-only")
            case "fd":
                return .unsupported(scheme: scheme, detail: detail,
                                    reason: "socket activation is not supported")
            default:
                return .unsupported(scheme: scheme, detail: detail,
                                    reason: "unrecognised transport")
            }
        }
        // A bare absolute path is unambiguous, and worth accepting because it
        // is what someone types into a settings field by hand.
        if text.hasPrefix("/") { return .unixSocket(path: text) }
        return nil
    }
}
