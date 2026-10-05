import AinkradAppKit
import Foundation
import Testing

@testable import ThrallFeature

@Suite("ThrallLogsModel")
struct ThrallLogsModelTests {
    private func frame(_ text: String, stream: ThrallLogStream = .stdout) -> ThrallLogFrame {
        ThrallLogFrame(stream: stream, payload: Data(text.utf8))
    }

    @MainActor
    @Test("tail populates visibleLines through AinkradLogBuffer")
    func tailPopulatesLines() async throws {
        let model = ThrallLogsModel()
        model.tail(containers: [(id: "c1", service: "web")]) { _ in
            [self.frame("log output\n")]
        }
        // Give async tailing task time to run
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.visibleLines.count == 1)
        #expect(model.visibleLines.first?.plainText == "log output")
    }
}
