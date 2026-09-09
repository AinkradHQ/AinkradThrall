import Foundation

/// A Docker Engine API version — `major.minor`, and nothing else.
///
/// A dedicated type rather than a `String` because every use of it is a
/// comparison, and string comparison gets this wrong in the one direction that
/// matters: `"1.9" > "1.54"` lexicographically, so a Podman compat layer
/// reporting `1.9` would look *newer* than the version Thrall targets and the
/// negotiation would pin a path the server cannot serve.
public struct ThrallAPIVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses `1.54`, or `1.54.0` with the patch ignored.
    ///
    /// The engine sends two components; Podman's compat layer has been seen to
    /// send three. Anything else is refused rather than coerced, because this
    /// value chooses the URL prefix for every subsequent request.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".",
                                                                    omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let major = Self.number(parts[0]), let minor = Self.number(parts[1]) else { return nil }
        if parts.count == 3, Self.number(parts[2]) == nil { return nil }
        self.major = major
        self.minor = minor
    }

    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 4, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(text)
    }

    public var description: String { "\(major).\(minor)" }

    /// The path prefix the engine expects, e.g. `/v1.51`.
    public var pathPrefix: String { "/v\(description)" }

    public static func < (lhs: ThrallAPIVersion, rhs: ThrallAPIVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}
