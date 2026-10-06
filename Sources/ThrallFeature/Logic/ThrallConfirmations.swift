import Foundation

/// The wording of Thrall's destructive confirmations.
///
/// Shared rather than written at each call site, because the message is the
/// only thing standing between the user and an irreversible action — and the
/// part that matters most is the reassurance, not the warning.
///
/// Basic mode hardcoded its own "This stops its containers and removes them",
/// which dropped both the container count AND the sentence saying named volumes
/// survive. On a destructive dialog that omission reads as "removes everything",
/// so the safe operation looks dangerous and the user cancels it.
enum ThrallConfirmations {

    /// Down: stops and removes containers, never volumes. Says so out loud.
    static func down(_ stack: ThrallStack) -> String {
        let count = stack.containerCount
        return "This stops and removes \(count) container\(count == 1 ? "" : "s") in "
            + "\(stack.displayName). Named volumes are kept — Thrall never removes a volume "
            + "as part of Down."
    }

    /// Teardown by label: the remedy for a stack nothing else can reach, so it
    /// says exactly how far it goes — and that volumes survive.
    static func teardown(_ stack: ThrallStack) -> String {
        let count = stack.containerCount
        return "\(stack.displayName)'s compose file is gone, so `docker compose down` cannot "
            + "reach it. Thrall will stop and remove its \(count) container"
            + "\(count == 1 ? "" : "s") by matching the compose project label. "
            + "**Volumes are not touched.**"
    }
}
