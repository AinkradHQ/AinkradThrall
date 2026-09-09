import Foundation
import Testing
@testable import ThrallFeature

/// Guards the captured 48-container response.
///
/// This is the Task C acceptance criterion and the input Task D's reconciler
/// is driven by, so the assertions are **exact**. Re-capturing the fixture on
/// a tidier machine would lose the hazards that make it valuable, and these
/// tests fail loudly rather than quietly adapt when that happens.
@Suite("The 48-container fixture")
struct ContainerFixtureTests {
    private func load() throws -> [ThrallContainerDTO] {
        let data = try Fixtures.data(Fixtures.containersAll48)
        return try JSONDecoder().decode([ThrallContainerDTO].self, from: data)
    }

    private func project(_ container: ThrallContainerDTO) -> String? {
        container.labels["com.docker.compose.project"]
    }

    private func workingDirectory(_ container: ThrallContainerDTO) -> String? {
        container.labels["com.docker.compose.project.working_dir"]
    }

    private func configFiles(_ container: ThrallContainerDTO) -> [String] {
        (container.labels["com.docker.compose.project.config_files"] ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    @Test("all 48 containers decode")
    func decodes() throws {
        let containers = try load()
        #expect(containers.count == 48)
        #expect(containers.allSatisfy { !$0.id.isEmpty })
        #expect(containers.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("the display name loses the engine's leading slash")
    func displayNameStripsSlash() throws {
        let containers = try load()
        #expect(containers.contains { $0.names.first == "/optimus-scheduler-1" })
        #expect(containers.contains { $0.displayName == "optimus-scheduler-1" })
        #expect(containers.allSatisfy { !$0.displayName.hasPrefix("/") })
    }

    /// Five projects and a flat list of 48 rows is why the Stack is the core
    /// object rather than the container.
    @Test("five compose projects, with the counts the machine actually has")
    func projectCounts() throws {
        let containers = try load()
        var counts: [String: Int] = [:]
        for container in containers {
            counts[project(container) ?? "<unlabelled>", default: 0] += 1
        }
        #expect(counts == [
            "aai1058": 24,
            "althaqeel": 12,
            "optimus": 8,
            "compose": 2,
            "<unlabelled>": 2,
        ])
    }

    /// **Task D's first spine test lives here.** Two unrelated trees both
    /// produce the project name `compose`, so a stack keyed on the name alone
    /// merges two different projects into one row. Identity must include the
    /// working directory.
    @Test("the project name `compose` is claimed by two different working directories")
    func projectNameIsNotAnIdentity() throws {
        let directories = Set(try load()
            .filter { project($0) == "compose" }
            .compactMap(workingDirectory))
        #expect(directories.count == 2)
        #expect(directories.contains { $0.contains("UlynkHomeCloud") })
        #expect(directories.contains { $0.contains("UlynkControlPlane") })
    }

    /// **Task D's second spine test.** `althaqeel` reports two working
    /// directories that differ only in the case of one component — the same
    /// directory on a case-insensitive filesystem. Keyed literally it splits
    /// one stack in two.
    @Test("althaqeel reports two working directories differing only in case")
    func caseOnlyDifference() throws {
        let directories = Set(try load()
            .filter { project($0) == "althaqeel" }
            .compactMap(workingDirectory))
        #expect(directories.count == 2)
        #expect(Set(directories.map { $0.lowercased() }).count == 1,
                "they are the same path once case is folded")
        #expect(directories.contains { $0.hasSuffix("/Run") })
        #expect(directories.contains { $0.hasSuffix("/run") })
    }

    /// The orphaned-stack case, and the largest stack here: containers whose
    /// compose file is gone from disk. `docker compose down` needs the file it
    /// was started from, so these are unreachable by normal tooling.
    @Test("aai1058 and compose declare config files that no longer exist")
    func orphanedStacks() throws {
        let containers = try load()
        var orphaned: [String: Int] = [:]
        for container in containers {
            guard let name = project(container) else { continue }
            let missing = configFiles(container).filter {
                !FileManager.default.fileExists(atPath: $0)
            }
            if !missing.isEmpty { orphaned[name, default: 0] += 1 }
        }
        #expect(orphaned == ["aai1058": 24, "compose": 2])
    }

    /// An orphaned stack's **working directory still exists** — only its
    /// compose files are gone. So `isConfigMissing` has to be keyed on the
    /// files, not on the directory, or `aai1058` reads as healthy.
    @Test("an orphaned stack can still have a working directory on disk")
    func workingDirectoryOutlivesTheConfig() throws {
        let containers = try load().filter { project($0) == "aai1058" }
        let directory = try #require(containers.compactMap(workingDirectory).first)
        #expect(configFiles(try #require(containers.first))
            .allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        // Recorded as an observation, not a requirement: it was true at capture
        // time and is what makes the directory a useless proxy for the config.
        #expect(directory.contains("scratchpad"))
    }

    /// The hazard found while building the transport: this label is a **list**.
    /// Treating it as one path yields a file that does not exist, and 24 of the
    /// 48 containers here would be misread.
    @Test("config_files is comma-separated, and 24 containers declare two")
    func configFilesIsAList() throws {
        let containers = try load()
        let multiple = containers.filter { configFiles($0).count > 1 }
        #expect(multiple.count == 24)
        #expect(multiple.allSatisfy { configFiles($0).count == 2 })
        #expect(multiple.allSatisfy { project($0) == "aai1058" })
    }

    /// The two containers belonging to no recognisable project. They get a real
    /// row in the loose-containers pseudo-stack; the `containers` area exists
    /// for exactly these.
    @Test("two containers carry no compose labels at all")
    func looseContainers() throws {
        let loose = try load().filter { project($0) == nil }
        #expect(loose.map(\.displayName).sorted() == ["ia565-pg", "ulynk-lan-pg"])
        // Labels arrive as `{}`, not null — the DTO defaults either to empty.
        #expect(loose.allSatisfy { $0.labels["com.docker.compose.service"] == nil })
    }

    @Test("the state distribution at capture time")
    func states() throws {
        var counts: [String: Int] = [:]
        for container in try load() { counts[container.state, default: 0] += 1 }
        // The 15 crash loops seen while planning had all given up by capture.
        #expect(counts == ["running": 19, "exited": 28, "created": 1])
    }

    /// Display only. Parsing an exit code out of this string is a
    /// localisation bug waiting to happen — `inspect` gives the number.
    @Test("Status is prose, which is why the exit code is read from inspect")
    func statusIsProse() throws {
        let statuses = Set(try load().map(\.status))
        #expect(statuses.contains { $0.hasPrefix("Exited (") && $0.contains("ago") })
        #expect(statuses.contains { $0.hasPrefix("Up ") })
    }

    /// Reachable only through the labels: `api` depends_on `db` comes free,
    /// with no compose file needed. It is what lets triage say "db is exited"
    /// instead of "12 things are red".
    @Test("depends_on is in the labels, so the dependency graph needs no compose file")
    func dependsOnIsLabelled() throws {
        let withDependencies = try load().filter {
            !($0.labels["com.docker.compose.depends_on"] ?? "").isEmpty
        }
        #expect(!withDependencies.isEmpty)
        let sample = try #require(withDependencies.first {
            ($0.labels["com.docker.compose.depends_on"] ?? "").contains(":")
        })
        // Shape: `redis:service_started:false,mysql:service_healthy:false`
        let clauses = (sample.labels["com.docker.compose.depends_on"] ?? "")
            .split(separator: ",")
        #expect(clauses.allSatisfy { $0.split(separator: ":").count == 3 })
    }
}
