import AinkradAppKit
import SwiftUI

/// Thrall's **basic** mode: the stacks, and the verbs that act on them.
///
/// Stacks are Thrall's core object and the reason it is usually opened — is it
/// up, and if not, bring it up. Triage, cross-stack logs, images, storage and
/// the flat container list all stay in advanced.
///
/// The saving is not only the rail. `refresh()` normally ends with
/// `scanForIncidents()`, which reads container logs to fingerprint crash loops
/// — work whose only consumers are the triage area and the rail's incident
/// badge. Basic has neither, so it turns the scan off rather than doing it and
/// throwing the result away.
///
/// Down still confirms. It is the one verb that destroys state, and a mode
/// being "basic" is not a reason to make the irreversible action quieter.
struct ThrallBasicView: View {
    private let host: HostServices
    @ObservedObject private var model: ThrallViewModel

    init(host: HostServices) {
        self.host = host
        self.model = ThrallRuntime.viewModel(for: host)
    }

    private var tokens: HostThemeTokens { host.theme.tokens }

    var body: some View {
        AinkradBasicShell(icon: "shippingbox", title: "Thrall", subtitle: subtitle) {
            StacksView(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background)
        .foregroundStyle(tokens.foreground)
        .ainkradHostTheme(host.theme)
        .thrallSession(model: model, host: host, skipsIncidentScan: true)
    }

    private var subtitle: String {
        if let version = model.engineVersion { return version.summary }
        return "connecting…"
    }
}
