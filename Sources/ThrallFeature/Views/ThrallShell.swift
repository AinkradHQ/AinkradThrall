import SwiftUI
import AinkradAppKit

/// The shell: a rail on the left, content on the right, and **no separator
/// line** between them. Surfaces are distinguished by fill, never by a rule —
/// the house rule is that it should look like an OS, not a web app.
public struct ThrallShell: View {
    private let host: HostServices
    @State private var area: NavArea = .stacks

    public init(host: HostServices) {
        self.host = host
    }

    public var body: some View {
        HStack(spacing: 0) {
            rail
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(host.theme.tokens.background)
        .ainkradHostTheme(host.theme)
    }

    private var rail: some View {
        VStack(spacing: AinkradSpacing.xs) {
            ForEach(NavArea.built) { item in
                RailItem(
                    area: item,
                    isSelected: item == area,
                    tokens: host.theme.tokens
                ) { area = item }
            }
            Spacer()
        }
        .padding(.vertical, AinkradSpacing.md)
        .padding(.horizontal, AinkradSpacing.sm)
        .frame(width: 56)
    }

    private var content: some View {
        AinkradEmptyState(
            icon: area.icon,
            title: area.title,
            message: "Not wired to an engine yet."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A rail entry. Hover changes fill and opacity only — never geometry — so
/// nothing in the rail shifts as the pointer crosses it.
private struct RailItem: View {
    let area: NavArea
    let isSelected: Bool
    let tokens: HostThemeTokens
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: area.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected ? tokens.accentPrimary : tokens.foreground.opacity(0.55))
                .frame(width: 40, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: AinkradRadius.sm, style: .continuous)
                        .fill(tokens.surface.opacity(isSelected ? 1 : (isHovering ? 0.55 : 0)))
                )
        }
        .buttonStyle(.plain)
        .help(area.title)
        .onHover { hovering in
            withAnimation(AinkradMotion.hover) { isHovering = hovering }
        }
    }
}
