import SwiftUI
import AinkradAppKit

/// Thrall's settings surface.
///
/// The Presentation control is backed by `HostServices.presentation`
/// (`PluginPresentationControl`), so the host persists the override and Thrall
/// keeps no copy of it. Per that contract the change lands the next time Thrall
/// is opened — it never morphs an already-open window.
struct ThrallSettingsView: View {
    let presentation: any PluginPresentationControl

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @State private var mode: PluginPresentation

    init(presentation: any PluginPresentationControl) {
        self.presentation = presentation
        _mode = State(initialValue: presentation.current)
    }

    var body: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                Text("Thrall drives the container engine you already run — it never owns one.")
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.foreground)

                AinkradFormRow(title: "Presentation", help: "Applies the next time Thrall opens.") {
                    AinkradSegmentedPicker(items: [PluginPresentation.overlay, .pane], selection: $mode) {
                        $0 == .overlay ? "Overlay" : "Pane"
                    }
                }
            }
        }
        .padding()
        // Top-aligned explicitly. The card is intrinsically sized, so without
        // this it floats wherever the container puts it — bottom of the pane in
        // the Dev Host — and settings that start halfway down the window read
        // as a rendering fault.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: mode) { _, newValue in presentation.set(newValue) }
    }
}
