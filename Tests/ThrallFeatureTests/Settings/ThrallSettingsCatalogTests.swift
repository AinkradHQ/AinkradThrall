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
        let page = ThrallSettingsCatalog.page(store: store, engine: Self.engine())
        #expect(page.groups.map(\.title) == ["Containers", "Thrall's engine"])
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

    /// An engine model over a scratch home, so no test touches ~/.thrall.
    private static func engine() -> ThrallOwnEngineModel {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        let paths = ThrallOwnEngine.Paths(
            root: home.appendingPathComponent(".thrall"),
            launchAgents: home.appendingPathComponent("Library/LaunchAgents"))
        return ThrallOwnEngineModel(installer: ThrallEngineInstaller(paths: paths, helperSource: nil))
    }

    @Test("the engine's size is written to engine.json, which the helper reads at boot")
    func engineFieldsWriteConfig() throws {
        let engine = Self.engine()
        let page = ThrallSettingsCatalog.page(store: ThrallSettingsStore(documents: MemoryDocs()), engine: engine)
        let fields = try #require(page.groups.last?.fields)
        #expect(fields.map(\.label) == ["CPUs", "Memory", "Start at login"])
        guard case .select(_, let cpus) = fields[0].kind, case .select(let memoryOptions, let memory) = fields[1].kind
        else {
            Issue.record("not selects")
            return
        }
        cpus.wrappedValue = "1"
        memory.wrappedValue = "8"
        #expect(ThrallEngineConfig.read(from: engine.paths.config) == ThrallEngineConfig(cpuCount: 1, memoryGiB: 8))
        #expect(memoryOptions.map(\.id) == ThrallEngineConfig.memoryChoices.map(String.init))
    }
}
