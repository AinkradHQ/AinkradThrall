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
    /// The same store the root view and `chromeFill` read — the trio that has
    /// to agree, which is what `ThrallRuntime` exists for.
    @ObservedObject var store: ThrallSettingsStore

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @State private var mode: PluginPresentation

    init(presentation: any PluginPresentationControl, store: ThrallSettingsStore) {
        self.presentation = presentation
        self.store = store
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

                AinkradFormRow(title: "Unmanaged containers",
                               help: "Containers with no compose project get their own row. "
                                   + "Two on this machine have no labels at all, and a running "
                                   + "container you cannot see is worse than a crowded list.") {
                    AinkradToggle(isOn: Binding(
                        get: { store.settings.showUnmanaged },
                        set: { store.settings.showUnmanaged = $0 }))
                }

                AinkradFormRow(title: "Confirm before Down",
                               help: "Down destroys state. Restart and Up never confirm — "
                                   + "gating an action that fixes a broken service is what "
                                   + "makes people stop using the tool.") {
                    AinkradToggle(isOn: Binding(
                        get: { store.settings.confirmBeforeDown },
                        set: { store.settings.confirmBeforeDown = $0 }))
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
