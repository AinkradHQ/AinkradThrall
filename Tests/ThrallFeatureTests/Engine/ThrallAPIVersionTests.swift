import Foundation
import Testing
@testable import ThrallFeature

@Suite("ThrallAPIVersion")
struct ThrallAPIVersionTests {
    @Test("parses what the engine and Podman send", arguments: [
        ("1.54", 1, 54), ("1.41", 1, 41), ("1.9", 1, 9), ("1.54.0", 1, 54), ("  1.51 ", 1, 51),
    ])
    func parses(text: String, major: Int, minor: Int) throws {
        let parsed = try #require(ThrallAPIVersion(text))
        #expect(parsed == ThrallAPIVersion(major: major, minor: minor))
    }

    @Test("refuses anything that is not a version", arguments: [
        "", "1", "1.", ".1", "v1.41", "1.41.2.3", "1.x", "latest", "-1.4", "1.41 beta", "99999.1",
    ])
    func refuses(text: String) {
        #expect(ThrallAPIVersion(text) == nil)
    }

    /// The reason this is a type and not a `String`. Lexically `"1.9" > "1.54"`,
    /// so a Podman compat layer reporting 1.9 would look newer than the version
    /// Thrall targets and negotiation would pin a path it cannot serve.
    @Test("compares numerically, where string comparison gets it backwards")
    func comparesNumerically() throws {
        let older = try #require(ThrallAPIVersion("1.9"))
        let newer = try #require(ThrallAPIVersion("1.54"))
        #expect(older < newer)
        #expect("1.9" > "1.54", "the string comparison this type exists to avoid")
        #expect(min(older, newer) == older)
    }

    @Test("renders the path prefix the engine expects")
    func pathPrefix() {
        #expect(ThrallAPIVersion(major: 1, minor: 51).pathPrefix == "/v1.51")
    }
}

@Suite("ThrallEngineNegotiation")
struct ThrallEngineNegotiationTests {
    /// This machine: reports 1.54, minimum 1.40. Thrall targets 1.51, so it
    /// pins 1.51 rather than reaching for a version it was not written against.
    @Test("a newer engine is pinned down to Thrall's target")
    func newerEngineIsPinnedDown() throws {
        let chosen = try ThrallEngineNegotiation.negotiate(
            reported: #require(ThrallAPIVersion("1.54")),
            serverMinimum: ThrallAPIVersion("1.40"))
        #expect(chosen == ThrallEngineNegotiation.target)
    }

    /// A Podman compat layer that lags: Thrall speaks down to it rather than
    /// sending a path it does not serve.
    @Test("an older engine is met where it is")
    func olderEngineIsMet() throws {
        let chosen = try ThrallEngineNegotiation.negotiate(
            reported: #require(ThrallAPIVersion("1.45")),
            serverMinimum: ThrallAPIVersion("1.24"))
        #expect(chosen == ThrallAPIVersion(major: 1, minor: 45))
    }

    /// **Fail closed.** Half the endpoints Thrall needs did not exist before
    /// 1.41, and degrading silently would show a half-populated machine as if
    /// it were the whole truth.
    @Test("below the floor it refuses rather than degrades", arguments: ["1.40", "1.24", "1.0"])
    func belowFloorFailsClosed(reported: String) throws {
        let version = try #require(ThrallAPIVersion(reported))
        #expect(throws: ThrallEngineError.apiTooOld(
            reported: reported,
            minimumSupported: ThrallEngineNegotiation.floor.description)) {
                try ThrallEngineNegotiation.negotiate(reported: version, serverMinimum: nil)
            }
    }

    @Test("a server that will not serve the chosen version is refused")
    func serverMinimumAboveChoice() throws {
        #expect(throws: ThrallEngineError.self) {
            try ThrallEngineNegotiation.negotiate(
                reported: #require(ThrallAPIVersion("1.45")),
                serverMinimum: #require(ThrallAPIVersion("1.46")))
        }
    }

    @Test("the floor is below the target, or nothing could ever negotiate")
    func floorIsBelowTarget() {
        #expect(ThrallEngineNegotiation.floor < ThrallEngineNegotiation.target)
    }
}
