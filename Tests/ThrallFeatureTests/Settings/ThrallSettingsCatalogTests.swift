import AinkradAppKit
import Foundation
import Testing

@testable import ThrallFeature

private final class MemoryDocs: PluginDocumentStore {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}

@Suite("Thrall — declared settings")
@MainActor
struct ThrallSettingsCatalogTests {
    @Test("both toggles are declared rows that write through and reset")
    func togglesAreDeclared() throws {
        let store = ThrallSettingsStore(documents: MemoryDocs())
        let page = ThrallSettingsCatalog.page(store: store)
        #expect(page.groups.map(\.title) == ["Containers"])
        let fields = try #require(page.groups.first?.fields)
        #expect(fields.map(\.label) == ["Unmanaged containers", "Confirm before Down"])

        guard case .toggle(let binding) = fields[1].kind else {
            Issue.record("not a toggle")
            return
        }
        binding.wrappedValue = false
        #expect(store.settings.confirmBeforeDown == false)
        #expect(fields[1].isModified() == true)
        fields[1].reset?()
        #expect(store.settings.confirmBeforeDown == true)
    }
}
