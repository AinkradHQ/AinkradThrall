import CryptoKit
import Foundation

/// Registers the `thrall` Docker context, so `docker context ls` and
/// Thrall's own context switcher both find the engine.
///
/// It writes only its own entry in the context store and **never touches
/// `config.json`**, so `currentContext` stays whatever the user chose. The
/// store directory name is `sha256(contextName)`, the layout
/// `ThrallContextResolver` already reads.
enum ThrallDockerContext {
    static let name = "thrall"

    static func register(socketPath: String, configDirectory: URL) throws {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = configDirectory.appendingPathComponent("contexts/meta/\(digest)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "Name": name,
            "Metadata": ["Description": "Thrall"],
            "Endpoints": ["docker": ["Host": "unix://\(socketPath)", "SkipTLSVerify": false]],
        ]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
    }
}
