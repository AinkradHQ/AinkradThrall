import Foundation

/// Shortens a path to something that fits **one line**.
///
/// Row height is not cosmetic here. `AinkradListRow` puts no line limit on its
/// subtitle, so a long path wraps and that row becomes taller than its
/// neighbours — which breaks the rule the whole list is built around: rows
/// never resize. The paths that do it are real and common; the `aai1058`
/// working directory on this machine is 96 characters of agent worktree.
///
/// Eliding the middle is also just better reading. `…/scratchpad/wt-1058` says
/// which worktree; the 60 characters of UUID in front of it say nothing a
/// person can use.
public enum ThrallPathDisplay {
    public static func abbreviate(_ path: String, maxLength: Int = 52) -> String {
        let tilded = (path as NSString).abbreviatingWithTildeInPath
        guard tilded.count > maxLength else { return tilded }

        let components = tilded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 2 else {
            // A single very long component cannot be elided by structure, so
            // cut the middle out of the text itself.
            return middleTruncated(tilded, maxLength: maxLength)
        }
        // Grow the tail while it fits: the end of a path is the part that
        // identifies it.
        var tail: [String] = []
        for component in components.reversed() {
            let candidate = (["…"] + [component] + tail).joined(separator: "/")
            if candidate.count > maxLength, !tail.isEmpty { break }
            tail.insert(component, at: 0)
            if tail.count == components.count { break }
        }
        if tail.count == components.count { return tilded }
        return (["…"] + tail).joined(separator: "/")
    }

    static func middleTruncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength, maxLength > 3 else { return text }
        let keep = maxLength - 1
        let head = keep - keep / 2
        let tail = keep / 2
        return text.prefix(head) + "…" + text.suffix(tail)
    }

    /// A one-line summary of what a service needs, capped so it cannot wrap.
    public static func dependencySummary(_ dependencies: [ThrallDependency],
                                         limit: Int = 3) -> String? {
        guard !dependencies.isEmpty else { return nil }
        let names = dependencies.map(\.service)
        if names.count <= limit { return "needs " + names.joined(separator: ", ") }
        return "needs " + names.prefix(limit).joined(separator: ", ")
            + " +\(names.count - limit) more"
    }
}
