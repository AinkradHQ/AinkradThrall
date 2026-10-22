import Foundation

// Compiled into BOTH the helper and the plugin (see project.yml): these are
// the two files they exchange under ~/.thrall, so one definition keeps the
// writer and the reader from drifting apart.

/// What the helper is doing, rewritten to `~/.thrall/run/status.json` on every
/// change and removed when it exits cleanly. No file means no helper running.
struct ThrallEngineStatus: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case starting, running, stopping, restarting, failed
    }

    var phase: Phase
    /// Seconds until the next start, while `restarting`.
    var retryInSeconds: Int?
    /// The configuration error, while `failed`.
    var failure: String?
    /// When the current VM finished booting.
    var runningSince: Date?
    /// Host ports forwarded to the guest, sorted.
    var forwardedPorts: [Int]
    /// Published ports that could not be forwarded because something on the
    /// Mac already holds them, sorted.
    var conflictedPorts: [Int]

    init(
        phase: Phase, retryInSeconds: Int? = nil, failure: String? = nil, runningSince: Date? = nil,
        forwardedPorts: [Int] = [], conflictedPorts: [Int] = []
    ) {
        self.phase = phase
        self.retryInSeconds = retryInSeconds
        self.failure = failure
        self.runningSince = runningSince
        self.forwardedPorts = forwardedPorts
        self.conflictedPorts = conflictedPorts
    }

    static func read(from url: URL) -> ThrallEngineStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The VM size the user chose, written by the plugin to
/// `~/.thrall/engine.json` and read by the helper before each boot. A missing
/// or unreadable file means the defaults.
struct ThrallEngineConfig: Codable, Equatable, Sendable {
    var cpuCount: Int
    var memoryGiB: Int

    static let memoryChoices = [2, 4, 6, 8, 12, 16]

    static func read(from url: URL) -> ThrallEngineConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
