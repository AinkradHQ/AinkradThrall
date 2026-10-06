import Foundation
import Testing

@testable import ThrallFeature

@Suite("ThrallPathKey")
struct ThrallPathKeyTests {
    @Test("case-only differences fold together")
    func foldsCase() {
        #expect(
            ThrallPathKey("/Users/me/Projects/Althaqeel/Run")
                == ThrallPathKey("/Users/me/Projects/althaqeel/run"))
    }

    @Test("a trailing slash is not an identity")
    func stripsTrailingSlash() {
        #expect(ThrallPathKey("/tmp/project/") == ThrallPathKey("/tmp/project"))
        #expect(ThrallPathKey("/") == ThrallPathKey("/"))
    }

    @Test("dot components are resolved")
    func standardizes() {
        #expect(ThrallPathKey("/tmp/a/../project") == ThrallPathKey("/tmp/project"))
        #expect(ThrallPathKey("/tmp/./project") == ThrallPathKey("/tmp/project"))
    }

    @Test("a tilde expands to the same key as the absolute path")
    func expandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ThrallPathKey("~/Projects/App") == ThrallPathKey("\(home)/Projects/App"))
    }

    @Test("genuinely different directories stay different")
    func keepsRealDifferences() {
        #expect(
            ThrallPathKey("/Users/me/Projects/UlynkHomeCloud/deploy/compose")
                != ThrallPathKey("/tmp/scratch/UlynkControlPlane/deploy/compose"))
    }

    @Test("decomposed and precomposed Unicode fold together")
    func normalizesUnicode() {
        // "café" with a combining acute versus a precomposed é — APFS can
        // report either.
        #expect(ThrallPathKey("/tmp/cafe\u{0301}") == ThrallPathKey("/tmp/caf\u{00E9}"))
    }
}
