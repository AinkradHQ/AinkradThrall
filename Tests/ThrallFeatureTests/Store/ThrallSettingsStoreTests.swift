import AinkradAppKit
import Foundation
import Testing

@testable import ThrallFeature

private final class SettingsDocs: PluginDocumentStore {
    var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) { storage[key] = data }
}

/// In-memory document store whose `setData` ignores backup keys, simulating a
/// failed verification read-back after the set-aside write.
private final class RejectingCorruptDocs: PluginDocumentStore {
    var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func setData(_ data: Data?, forKey key: String) {
        if key.contains(".corrupt-") { return }
        storage[key] = data
    }
}

@Suite("ThrallSettingsStore")
@MainActor
struct ThrallSettingsStoreTests {
    @Test("corrupt document is set aside, not overwritten")
    func corruptDocumentIsSetAsideNotOverwritten() {
        let seed = Data("{not json".utf8)
        let docs = SettingsDocs()
        docs.setData(seed, forKey: "thrall.settings.v1")
        let store = ThrallSettingsStore(documents: docs)
        store.settings.pollSeconds = 10
        let backups = docs.storage.keys.filter {
            $0.hasPrefix("thrall.settings.v1.corrupt-")
        }
        #expect(backups.count == 1, "corrupt bytes were not set aside")
        #expect(docs.storage[backups.first ?? ""] == seed, "backup does not hold the seed bytes")
    }

    @Test("unverifiable set-aside keeps the original and stops saving")
    func unverifiableSetAsideKeepsOriginalAndStopsSaving() {
        let seed = Data("{not json".utf8)
        let docs = RejectingCorruptDocs()
        docs.setData(seed, forKey: "thrall.settings.v1")
        let store = ThrallSettingsStore(documents: docs)
        store.settings.pollSeconds = 10
        #expect(
            docs.storage["thrall.settings.v1"] == seed,
            "the only copy of the user's data was overwritten")
    }
}
