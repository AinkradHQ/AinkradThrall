import Foundation

@testable import ThrallFeature

// Conveniences only tests use. Kept out of the module so production code
// cannot come to depend on them.

extension ThrallFileProbe {
    /// Everything is gone — the orphaned-stack world.
    static let nothingExists = ThrallFileProbe { _ in false }
    /// Everything is present.
    static let everythingExists = ThrallFileProbe { _ in true }
}

extension ThrallEventHistory {
    /// Every service with recorded deaths.
    var trackedServices: [ServiceKey] { Array(deaths.keys) }
}
