import Foundation
import Testing

@testable import ThrallFeature

/// Row height is not cosmetic: `AinkradListRow` puts no line limit on its
/// subtitle, so a path that wraps makes its row taller than its neighbours and
/// breaks the rule the list is built around. Caught by screenshot, fixed here.
@Suite("ThrallPathDisplay")
struct ThrallPathDisplayTests {
    @Test("a short path is left alone, with the home directory abbreviated")
    func shortPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(
            ThrallPathDisplay.abbreviate("\(home)/Home/Projects/Optimus/Run")
                == "~/Home/Projects/Optimus/Run")
    }

    /// The real offender: 96 characters of agent worktree, of which only the
    /// last two components mean anything to a person.
    @Test("a long path keeps its tail and elides the middle")
    func longPath() {
        let path =
            "/private/tmp/claude-501/-Users-ahmedmelhalaby-Home-Projects-AutomotiveAi"
            + "/0ab18311-2c30-4dcd-a4da-4d1f9b3535e7/scratchpad/wt-1058"
        let short = ThrallPathDisplay.abbreviate(path)
        #expect(short.count <= 52)
        #expect(short.hasPrefix("…/"))
        #expect(short.hasSuffix("/wt-1058"), "the identifying end must survive")
    }

    @Test("every real working directory in the fixture fits on one line")
    func everyFixturePathFits() throws {
        let containers = try JSONDecoder().decode(
            [ThrallContainerDTO].self, from: try Fixtures.data(Fixtures.containersAll48))
        let directories = Set(
            containers.compactMap {
                $0.labels["com.docker.compose.project.working_dir"]
            })
        #expect(!directories.isEmpty)
        for directory in directories {
            #expect(
                ThrallPathDisplay.abbreviate(directory).count <= 52,
                Comment(rawValue: directory))
        }
    }

    @Test("a single enormous component is cut through the middle")
    func singleComponent() {
        let short = ThrallPathDisplay.abbreviate("/" + String(repeating: "x", count: 200))
        #expect(short.count <= 52)
        #expect(short.contains("…"))
    }

    @Test("a dependency list is capped rather than allowed to wrap")
    func dependencySummary() {
        let many = (1...6).map {
            ThrallDependency(
                service: "service-\($0)", condition: "service_started",
                restartsDependents: false)
        }
        let summary = try? #require(ThrallPathDisplay.dependencySummary(many))
        #expect(summary == "needs service-1, service-2, service-3 +3 more")
        #expect(ThrallPathDisplay.dependencySummary([]) == nil)
    }

    @Test("a short dependency list is listed in full")
    func shortDependencySummary() {
        let two = ["pgsql", "redis"].map {
            ThrallDependency(service: $0, condition: "service_healthy", restartsDependents: false)
        }
        #expect(ThrallPathDisplay.dependencySummary(two) == "needs pgsql, redis")
    }
}
