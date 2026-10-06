import AinkradAppKit

/// A finished action's outcome, shown as a toast. The status is chosen by the
/// code that knows how the action ended, never guessed from the wording.
struct ThrallNotice: Equatable, Sendable {
    let message: String
    let status: AinkradStatus
}
