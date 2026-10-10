import AinkradAppKit
import SwiftUI

/// The label of a pull-down `AinkradMenuButton`, dressed in the kit's trigger
/// role (`skin.roles.trigger`): the shape, fill, edge, chevron and padding that
/// `AinkradSelect` draws on its own trigger.
///
/// Local only because the kit draws that trigger inside `AinkradSelect` and
/// does not expose it as a view a menu button can use as its label. A public
/// pull-down trigger label is an Epic 4 gap; until then every value here comes
/// from the skin.
struct ThrallPullDownLabel<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTypography) private var typo

    @ViewBuilder var body: some View {
        if #available(macOS 26, *), skin.usesNativeGlass {
            // Liquid Glass: Apple's pop-up button look — the value and the
            // up/down chevrons on an interactive glass capsule.
            HStack(spacing: skin.spacing.xs) {
                content
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, skin.spacing.md)
            .padding(.vertical, skin.spacing.sm)
            .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            kitBody
        }
    }

    private var kitBody: some View {
        let trigger = skin.roles.trigger
        let shape = AinkradSkinShape(token: trigger.shape)
        return HStack(spacing: skin.spacing.xs) {
            content
            Image(systemName: "chevron.down")
                .font(skin.font(trigger.chevron, typography: typo))
                .foregroundStyle(skin.color(trigger.chevronColor))
        }
        .padding(.horizontal, skin.spacing.md)
        .padding(.vertical, skin.spacing.sm)
        .background(shape.fill(skin.color(trigger.fill)))
        .overlay(
            shape.strokeBorder(
                skin.color(trigger.stroke.color), lineWidth: trigger.stroke.width.resolve([])))
    }
}
