import Testing
@testable import ThrallFeature

/// Thrall's areas are argued from how the machine actually looks, so the
/// ordering is a decision worth pinning rather than an accident of the enum.
@Suite("NavArea")
struct NavAreaTests {
    @Test("triage comes first, because the opening statement is what is broken")
    func triageIsFirst() {
        #expect(NavArea.built.first == .triage)
    }

    @Test("every area has a title and an SF Symbol")
    func everyAreaIsRenderable() {
        for area in NavArea.built {
            #expect(!area.title.isEmpty)
            #expect(!area.icon.isEmpty)
        }
    }

    @Test("ids are unique — they key selection and persisted UI state")
    func idsAreUnique() {
        #expect(Set(NavArea.built.map(\.id)).count == NavArea.built.count)
    }
}
