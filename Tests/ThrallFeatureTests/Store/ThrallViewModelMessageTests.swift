import Foundation
import Testing

@testable import ThrallFeature

/// The messages a user actually reads. Raw framework text reaching a window is
/// a defect, and this is where it gets caught.
@Suite("ThrallViewModel messages")
struct ThrallViewModelMessageTests {
    /// The real home directory, so the tilde abbreviation is exercised rather
    /// than skipped — `desktop-linux`'s socket path on this machine.
    private let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".docker/run/docker.sock").path
    private var socket: ThrallEngineEndpoint { .unixSocket(path: socketPath) }

    /// The normal state of a configured-but-stopped engine — `desktop-linux`
    /// on this machine. Network.framework calls it
    /// `POSIXErrorCode(rawValue: 2)`, which is true and useless.
    @Test(
        "a missing socket names the engine, not the errno",
        arguments: [
            "POSIXErrorCode(rawValue: 2): No such file or directory",
            "POSIXErrorCode(rawValue: 61): Connection refused",
        ])
    func missingSocket(detail: String) {
        let message = ThrallViewModel.describe(.connectionFailed(detail), endpoint: socket)
        #expect(
            message == "Nothing is listening at ~/.docker/run/docker.sock. "
                + "Start the engine and try again.",
            Comment(rawValue: message))
        #expect(!message.contains("POSIXErrorCode"))
        #expect(!message.contains("rawValue"))
    }

    @Test("an unrecognised connection failure still shows its detail")
    func otherConnectionFailure() {
        let message = ThrallViewModel.describe(
            .connectionFailed("protocol error"),
            endpoint: socket)
        #expect(message.contains("protocol error"))
    }

    @Test("an engine error passes the engine's own words through unchanged")
    func engineMessageIsNotParaphrased() {
        let message = ThrallViewModel.describe(
            ThrallEngineError.http(status: 409, message: "container abc is not running"))
        #expect(message.contains("container abc is not running"))
    }

    @Test("a too-old engine says what it needs")
    func tooOld() {
        let message = ThrallViewModel.describe(
            ThrallEngineError.apiTooOld(reported: "1.40", minimumSupported: "1.41"))
        #expect(message.contains("1.40") && message.contains("1.41"))
    }

    /// A bare `"\(error)"` prints the case name and its payload. Every error a
    /// view can show must instead carry the sentence the user reads.
    @Test("Thrall's errors read as sentences through localizedDescription")
    func localizedDescriptions() {
        let errors: [any Error] = [
            ThrallEngineError.http(status: 409, message: "conflict"),
            ThrallTransportError.timedOut,
            ThrallProcessError.cancelled,
            ThrallExecError.emptyCommand,
            ThrallComposeArgumentGuard.Rejection.subcommand("exec"),
        ]
        for error in errors {
            let text = error.localizedDescription
            #expect(!text.contains("ThrallFeature"), Comment(rawValue: text))
            #expect(!text.contains("error 1"), Comment(rawValue: text))
        }
        #expect(
            ThrallEngineError.http(status: 409, message: "conflict").localizedDescription
                == "The engine returned 409: conflict")
        #expect(ThrallTransportError.timedOut.localizedDescription == "The engine did not answer in time.")
        #expect(ThrallExecError.emptyCommand.localizedDescription == "Type a command.")
    }
}
