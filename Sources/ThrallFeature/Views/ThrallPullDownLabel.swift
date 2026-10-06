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

    var body: some View {
        let trigger = skin.roles.trigger
        let shape = AinkradSkinShape(token: trigger.shape)
        HStack(spacing: skin.spacing.xs) {
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
