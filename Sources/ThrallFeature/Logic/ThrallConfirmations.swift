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

    /// Uninstalling Thrall's own engine deletes its whole disk. The message
    /// names what is on it, volumes by name, because that is the one thing a
    /// user cannot get back; and it says what is safe, the project folders.
    static func uninstallEngine(_ contents: ThrallEngineContents?) -> String {
        let deleted: String
        if let contents {
            let names = contents.volumeNames.prefix(4).joined(separator: ", ")
            let more = contents.volumeNames.count > 4 ? ", and \(contents.volumeNames.count - 4) more" : ""
            let volumes =
                contents.volumeNames.isEmpty
                ? "no volumes"
                : "\(contents.volumeNames.count) volume\(contents.volumeNames.count == 1 ? "" : "s") (\(names)\(more))"
            deleted =
                "\(contents.containers) container\(contents.containers == 1 ? "" : "s"), \(volumes) and "
                + "\(contents.images) image\(contents.images == 1 ? "" : "s")"
        } else {
            deleted = "every container, volume and image on its disk"
        }
        return "This stops the engine and deletes ~/.thrall, with \(deleted). Your project folders are "
            + "not touched: they were shared with the VM, never copied into it."
    }

    /// The destructive button repeats the count, so it cannot be pressed
    /// without reading it.
    static func uninstallEngineButton(_ contents: ThrallEngineContents?) -> String {
        guard let count = contents?.volumeNames.count, count > 0 else { return "Uninstall" }
        return "Delete \(count) volume\(count == 1 ? "" : "s") and uninstall"
    }
}
