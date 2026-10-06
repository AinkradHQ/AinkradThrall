import AinkradAppKit
import Foundation
import Testing

@testable import ThrallFeature

@Suite("ThrallLogsModel")
struct ThrallLogsModelTests {
    private func frame(_ text: String, stream: ThrallLogStream = .stdout) -> ThrallLogFrame {
        frame(Data(text.utf8), stream: stream)
    }

    private func frame(_ bytes: Data, stream: ThrallLogStream = .stdout) -> ThrallLogFrame {
        ThrallLogFrame(stream: stream, payload: bytes)
    }

    /// Tails one container and waits until the read has been applied.
    @MainActor
    private func tail(_ frames: [ThrallLogFrame]) async throws -> ThrallLogsModel {
        let model = ThrallLogsModel()
        model.tail(containers: [(id: "c1", service: "web")]) { _ in frames }
        for _ in 0..<200 where model.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoading)
        return model
    }

    @MainActor
    @Test("tail populates visibleLines through AinkradLogBuffer")
    func tailPopulatesLines() async throws {
        let model = try await tail([frame("log output\n")])
        #expect(model.visibleLines.count == 1)
        #expect(model.visibleLines.first?.plainText == "log output")
    }

    @MainActor
    @Test("a UTF-8 character split across two frames is decoded whole")
    func utf8SplitAcrossFrames() async throws {
        let bytes = Data("caf\u{e9}\n".utf8)  // é is C3 A9
        let split = bytes.firstIndex(of: 0xC3)! + 1
        let model = try await tail([
            frame(bytes.subdata(in: 0..<split)), frame(bytes.subdata(in: split..<bytes.count)),
        ])
        #expect(model.visibleLines.map(\.plainText) == ["caf\u{e9}"])
    }

    @MainActor
    @Test("a CRLF split across two frames is one line break")
    func crlfSplitAcrossFrames() async throws {
        let model = try await tail([frame("one\r"), frame("\ntwo\r\n")])
        #expect(model.visibleLines.map(\.plainText) == ["one", "two"])
    }

    @MainActor
    @Test("a flushed partial stderr line stays stderr")
    func partialStderrStaysStderr() async throws {
        let model = try await tail([frame("out\n"), frame("no newline", stream: .stderr)])
        #expect(model.visibleLines.map(\.plainText) == ["out", "no newline"])
        #expect(model.visibleLines.map(\.stream) == [.stdout, .stderr])
    }

    @MainActor
    @Test("stdin frames are shown as stdout")
    func stdinMapsToStdout() async throws {
        let model = try await tail([frame("typed\n", stream: .stdin)])
        #expect(model.visibleLines.map(\.stream) == [.stdout])
    }
}
