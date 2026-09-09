import Foundation

/// Parses the engine's RFC 3339 timestamps.
///
/// **Uses `Date.ISO8601FormatStyle`, not `ISO8601DateFormatter`,** and that is
/// the whole content of this file. The engine mixes two shapes *in the same
/// response* — `/system/df` puts fractional build-cache timestamps beside
/// non-fractional volume ones — and `ISO8601DateFormatter` cannot read both
/// with one configuration. Measured against this machine's daemon:
///
/// | value | formatter, `.withFractionalSeconds` | formatter, plain |
/// |---|---|---|
/// | `2026-09-09T11:02:54.532431428Z` | parses | **nil** |
/// | `2026-08-24T09:31:56+03:00` | **nil** | parses |
///
/// So the formatter needs a two-attempt dance, and it is also not `Sendable`,
/// which under strict concurrency means it cannot be a `static let` without a
/// lock around it. `Date.ISO8601FormatStyle` is a value type, is `Sendable`,
/// and parses **every** shape above whichever way `includingFractionalSeconds`
/// is set — verified against all four. One style, no lock, no fallback.
///
/// **The zero time is a sentinel, not a date.** A running container reports
/// `FinishedAt: "0001-01-01T00:00:00Z"`, which parses perfectly and renders as
/// "exited 2025 years ago". It maps to nil here so no view has to know.
public enum ThrallEngineTimestamp {
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The Go zero time, which the engine sends for "this never happened".
    static let zeroTimePrefix = "0001-01-01T00:00:00"

    public static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        guard !raw.hasPrefix(zeroTimePrefix) else { return nil }
        return try? style.parse(raw)
    }
}
