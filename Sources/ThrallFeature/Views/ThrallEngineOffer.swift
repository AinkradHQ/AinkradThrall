import AinkradAppKit
import SwiftUI

/// Mockup screen 2: no engine answers, so Thrall offers its own, saying what
/// the user agrees to before they click. Built on the kit's empty state, with
/// the facts as chips under it.
struct ThrallEngineOffer: View {
    @ObservedObject var engine: ThrallOwnEngineModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: AinkradSpacing.md) {
            switch engine.phase {
            case .unsupported:
                AinkradEmptyState(
                    icon: "shippingbox", title: "No container engine is running",
                    message: "Start OrbStack, Docker Desktop or Podman. Thrall's own engine needs an Apple silicon Mac."
                )
            case .installFailed(let reason):
                offer(message: reason, primary: "Try again")
            default:
                offer(
                    message: "Thrall can run its own engine: a small Linux VM on this Mac, with Docker inside. "
                        + "Your home folder is shared with it, so compose files and bind mounts work unchanged, "
                        + "and published ports open on localhost.",
                    primary: "Install Thrall's engine")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func offer(message: String, primary: String) -> some View {
        VStack(spacing: AinkradSpacing.md) {
            AinkradEmptyState(
                icon: "shippingbox", title: "No container engine is running", message: message,
                actionTitle: primary, action: { engine.install() }
            )
            .secondaryAction("I'll start my own engine", action: dismiss)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AinkradSpacing.sm) {
                AinkradChip(label: "116 MB download")
                AinkradChip(label: "Apple silicon")
                AinkradChip(label: "Keeps running after you quit Ainkrad")
                AinkradChip(label: "Lives in ~/.thrall")
            }
        }
    }
}
