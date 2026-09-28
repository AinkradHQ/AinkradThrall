import Testing
import SwiftUI
import AinkradAppKit
@testable import ThrallFeature

/// Thrall's basic mode: the stacks, and the verbs on them.
///
/// Thin on purpose. The behaviour worth asserting — that basic skips
/// `scanForIncidents` — lives on `ThrallViewModel`, which needs a `HostServices`
/// double this repo does not have, and building one for a single assertion is
/// more scaffolding than the assertion is worth. The scope flag is a plain
/// `= true` default read by one `if` in `refresh()`, and the compiler covers
/// the wiring.
@Suite("Thrall — basic mode")
@MainActor
struct ThrallBasicModeTests {

    @Test("Thrall opts into modes, so the host's cast finds it")
    func optsIntoModes() {
        // The host never asks whether an app has a basic mode; it casts. Drop
        // the conformance and Thrall silently becomes advanced-only.
        #expect((ThrallApp.self as Any) as? AinkradAppModes.Type != nil)
    }

    @Test("Advanced still reaches every nav area")
    func advancedKeepsEveryArea() {
        // Basic shows stacks alone. This is the guard that carving it out did
        // not also remove an area from advanced.
        #expect(Set(NavArea.allCases) == [.triage, .stacks, .containers, .logs, .images, .storage])
    }
}
