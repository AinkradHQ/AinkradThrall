import Foundation
import Testing

@testable import ThrallFeature

@Suite("ThrallComposeCommand")
struct ThrallComposeCommandTests {
    @Test("config files keep their order — later files override earlier ones")
    func fileOrderPreserved() throws {
        let arguments = try ThrallComposeCommand(
            verb: .up, projectName: "aai1058", projectDirectory: "/tmp/wt",
            configFiles: ["/tmp/wt/docker-compose.yml", "/tmp/wt/docker-compose.dev.yml"]
        )
        .arguments()
        let files = zip(arguments, arguments.dropFirst())
            .filter { $0.0 == "-f" }.map(\.1)
        #expect(files == ["/tmp/wt/docker-compose.yml", "/tmp/wt/docker-compose.dev.yml"])
    }

    /// This machine has 26 containers whose compose file moved — which is
    /// exactly how an orphan is created, so `up` cleans them up.
    @Test("up detaches and removes orphans")
    func upOptions() throws {
        let arguments = try ThrallComposeCommand(
            verb: .up, projectName: "x",
            projectDirectory: "/tmp",
            configFiles: ["/tmp/c.yml"]
        ).arguments()
        #expect(arguments.contains("-d"))
        #expect(arguments.contains("--remove-orphans"))
    }

    @Test("service names are placed after an option terminator")
    func servicesAfterTerminator() throws {
        let arguments = try ThrallComposeCommand(
            verb: .restart, projectName: "x",
            projectDirectory: "/tmp",
            configFiles: ["/tmp/c.yml"],
            services: ["api"]
        ).arguments()
        let terminator = try #require(arguments.firstIndex(of: "--"))
        #expect(arguments[(terminator + 1)...] == ["api"])
    }

    /// An orphaned stack cannot use these at all: every one needs the file the
    /// stack was started from.
    @Test("the verbs that read the compose file are marked as needing it")
    func requiresConfigFiles() {
        for verb in [ThrallComposeCommand.Verb.up, .down, .pull, .config, .ps] {
            #expect(
                ThrallComposeCommand(
                    verb: verb, projectName: "x", projectDirectory: "/tmp",
                    configFiles: []
                ).requiresConfigFiles)
        }
        for verb in [ThrallComposeCommand.Verb.start, .stop, .restart] {
            #expect(
                !ThrallComposeCommand(
                    verb: verb, projectName: "x", projectDirectory: "/tmp",
                    configFiles: []
                ).requiresConfigFiles)
        }
    }

    @Test("a project name that is not an identifier is refused")
    func invalidProjectName() {
        #expect(throws: ThrallComposeArgumentGuard.Rejection.identifier("--rm")) {
            try ThrallComposeCommand(
                verb: .up, projectName: "--rm", projectDirectory: "/tmp",
                configFiles: []
            ).arguments()
        }
    }
}
