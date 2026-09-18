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
    let modeControl: any PluginModeControl
    /// The same store the root view and `chromeFill` read — the trio that has
    /// to agree, which is what `ThrallRuntime` exists for.
    @ObservedObject var store: ThrallSettingsStore

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    init(presentation: any PluginPresentationControl,
         modeControl: any PluginModeControl,
         store: ThrallSettingsStore) {
        self.presentation = presentation
        self.modeControl = modeControl
        self.store = store
    }

    var body: some View {
        AinkradCard {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                Text("Thrall drives the container engine you already run — it never owns one.")
                    .font(AinkradFontResolver.font(.body, typography: typo))
                    .foregroundStyle(theme.foreground)

                // The shared rows, not a local copy: "Open as" and "Open in"
                // must read the same and sit in the same place in every app.
                AinkradSurfaceSettings(appName: "Thrall",
                                       presentation: presentation,
                                       mode: modeControl)

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
    }
}
