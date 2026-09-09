import Foundation

/// An ordered, case-insensitive header collection.
///
/// Case-insensitivity is not a nicety here. The single most consequential
/// decision in the log path is made by reading `Content-Type`, and the field
/// name's case is not guaranteed by anything — HTTP/1.1 field names are
/// case-insensitive (RFC 9110 5.1), and a proxy or a Podman compat layer may
/// spell it differently from the Docker engine. A dictionary keyed on the
/// as-received spelling would silently miss it and fall through to
/// "unrecognised framing".
///
/// Insertion order is preserved because it is the only thing that makes a
/// captured response byte-comparable in a test.
public struct ThrallHTTPHeaders: Equatable, Sendable {
    /// As received, in order. The spelling is kept for display and fixtures.
    public private(set) var fields: [(name: String, value: String)] = []
    /// Lowercased name -> every value under it, in order.
    private var index: [String: [String]] = [:]

    public init() {}

    public init(_ fields: [(String, String)]) {
        for field in fields { append(name: field.0, value: field.1) }
    }

    public mutating func append(name: String, value: String) {
        fields.append((name, value))
        index[name.lowercased(), default: []].append(value)
    }

    /// The first value under `name`, or nil. Use this for a field that is
    /// singular by definition (`Content-Type`, `Api-Version`).
    public func first(_ name: String) -> String? {
        index[name.lowercased()]?.first
    }

    /// Every value under `name`, in order. Use this where a repeated field is
    /// legal and *meaningful* — `Content-Length` appearing twice with
    /// different values is a framing attack, and the parser must be able to
    /// see both to refuse it rather than take the first and continue.
    public func values(_ name: String) -> [String] {
        index[name.lowercased()] ?? []
    }

    public func contains(_ name: String) -> Bool {
        index[name.lowercased()] != nil
    }

    public static func == (lhs: ThrallHTTPHeaders, rhs: ThrallHTTPHeaders) -> Bool {
        lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}
