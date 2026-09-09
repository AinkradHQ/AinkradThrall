import Foundation

/// A filesystem path reduced to something two spellings of the same directory
/// agree on, kept **separate from the spelling itself**.
///
/// This exists because of two measured facts about the containers on this
/// machine, which pull in opposite directions:
///
///  * `althaqeel` reports two working directories, `…/Althaqeel/Run` and
///    `…/Althaqeel/run`. They are the same directory — macOS is
///    case-insensitive by default — so a literal key **splits one stack in
///    two**.
///  * The project name `compose` is claimed by two genuinely unrelated trees,
///    so the working directory is the only thing that keeps them apart and it
///    cannot be dropped.
///
/// Hence: fold the path hard enough that case and symlinks stop mattering,
/// and keep the engine's own spelling for display so the UI still shows the
/// path the user recognises.
///
/// **Case folding is unconditional, and that is a deliberate simplification.**
/// A case-sensitive APFS volume would make `/Run` and `/run` genuinely
/// different, and this would merge them wrongly. Weighed against the observed
/// case — a real stack that really does need merging — and the alternative of
/// a volume-capability probe per path, folding always is the better trade. If
/// a case-sensitive volume ever turns up, this is the one place to fix.
public struct ThrallPathKey: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ raw: String) {
        var path = (raw as NSString).expandingTildeInPath
        // Resolves `..` and `.`, then follows symlinks. Both are no-ops for a
        // path that no longer exists — which is the `compose` case, and it
        // still splits correctly because the two paths differ well above any
        // link.
        path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        // APFS can hand back decomposed Unicode, so a directory with an
        // accent in its name would otherwise key differently depending on
        // which API reported it.
        value = path.precomposedStringWithCanonicalMapping.lowercased()
    }

    public var description: String { value }
}
