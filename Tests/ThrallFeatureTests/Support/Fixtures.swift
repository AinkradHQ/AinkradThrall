import Foundation
import Testing

/// Loads captured engine responses from `Tests/ThrallFeatureTests/Fixtures/`.
///
/// Located relative to `#filePath` rather than through a resource bundle,
/// matching `BundleMetadataTests`. The test target is an `xcodebuild` unit-test
/// bundle, and declaring a resources phase for one JSON file would add build
/// plumbing to gain nothing: these tests only ever run from the source tree.
enum Fixtures {
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // ThrallFeatureTests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// `GET /containers/json?all=1` captured verbatim from this machine's
    /// OrbStack daemon on 2026-09-09. Re-capture with:
    ///
    ///     curl -s --unix-socket ~/.orbstack/run/docker.sock \
    ///       "http://d/v1.51/containers/json?all=1" \
    ///       > Tests/ThrallFeatureTests/Fixtures/containers-all-48.json
    ///
    /// Kept because it is the only input that carries every identity hazard at
    /// once — see `ContainerFixtureTests`, which asserts they are all still in
    /// it. A re-capture that loses one silently weakens Task D's spine tests,
    /// so those assertions fail rather than adapt.
    static let containersAll48 = "containers-all-48.json"
}
