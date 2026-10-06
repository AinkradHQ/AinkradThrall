import AinkradAppKit
import Foundation
import os

/// Reads `key`. Bytes that no longer decode are MOVED to `<key>.corrupt-<UTC stamp>`
/// (verified by reading the copy back) and the caller starts empty. If the copy
/// cannot be verified the original stays where it is and `canSave` is false, so
/// nothing ever writes over the only copy of the user's data.
func loadDocument<T: Decodable>(
    _ type: T.Type, key: String, from documents: PluginDocumentStore,
    decoder: JSONDecoder = JSONDecoder(), app: String, now: Date = Date()
) -> (value: T?, canSave: Bool) {
    guard let data = documents.data(forKey: key) else { return (nil, true) }
    do {
        return (try decoder.decode(T.self, from: data), true)
    } catch {
        let log = AinkradLog.logger(app: app, area: "persistence")
        let stamp = now.formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))
        let backup = "\(key).corrupt-\(stamp)"
        documents.setData(data, forKey: backup)
        guard documents.data(forKey: backup) == data else {
            log.error("\(key, privacy: .public) does not decode and could not be set aside; saving is off: \(error)")
            return (nil, false)
        }
        documents.setData(nil, forKey: key)
        log.error("\(key, privacy: .public) does not decode; moved to \(backup, privacy: .public): \(error)")
        return (nil, true)
    }
}
