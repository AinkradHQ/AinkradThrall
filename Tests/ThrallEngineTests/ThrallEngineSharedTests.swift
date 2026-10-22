import Foundation
import Testing

@Suite("Thrall engine shared files")
struct ThrallEngineSharedTests {
    @Test("engine.json overrides the defaults, clamped to this Mac's cores")
    func configResolution() {
        #expect(ThrallVMSpec.resolved(config: nil, processorCount: 10) == .defaults(processorCount: 10))
        let chosen = ThrallVMSpec.resolved(config: ThrallEngineConfig(cpuCount: 6, memoryGiB: 8), processorCount: 10)
        #expect(chosen.cpuCount == 6)
        #expect(chosen.memoryBytes == 8 * ThrallVMSpec.gibibyte)
        #expect(
            ThrallVMSpec.resolved(config: ThrallEngineConfig(cpuCount: 64, memoryGiB: 4), processorCount: 10).cpuCount
                == 10)
    }

    @Test("status.json round-trips, and an unreadable file reads as no status")
    func statusRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString).json")
        let status = ThrallEngineStatus(
            phase: .running, runningSince: Date(timeIntervalSince1970: 1_800_000_000),
            forwardedPorts: [3000, 8080], conflictedPorts: [5432])
        try status.write(to: url)
        #expect(ThrallEngineStatus.read(from: url) == status)
        try Data("not json".utf8).write(to: url)
        #expect(ThrallEngineStatus.read(from: url) == nil)
    }
}
