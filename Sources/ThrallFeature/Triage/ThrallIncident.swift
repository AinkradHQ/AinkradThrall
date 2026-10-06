import AinkradAppKit
import Foundation

/// Normalises a log line so two containers failing the same way produce the
/// same fingerprint.
///
/// Every one of these substitutions was chosen because it is the thing that
/// differs between two containers with **one** shared cause: a timestamp, a
/// pid, a container id, an ephemeral port, a hex hash. Leave any of them in
/// and 12 workers dying on `connection refused` fingerprint as 12 distinct
/// incidents — which is precisely the failure the grouping exists to prevent.
enum ThrallLogFingerprint {
    /// Order matters: the long, specific patterns run before the general
    /// number sweep, or a timestamp becomes three separate `<n>` tokens and
    /// stops being recognisable.
    static let specs: [(pattern: String, replacement: String)] = [
        // ISO-8601 and syslog timestamps.
        (#"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#, "<ts>"),
        (#"\d{2}:\d{2}:\d{2}(?:\.\d+)?"#, "<ts>"),
        // A 64- or 12-char hex blob: container ids, digests, hashes.
        (#"\b[0-9a-f]{12,64}\b"#, "<hex>"),
        // `pid 12345`, `[pid: 123]`.
        (#"(?i)\bpid[:= ]+\d+"#, "pid <n>"),
        // `host:5432`, `0.0.0.0:8080`.
        (#":\d{2,5}\b"#, ":<port>"),
        // UUIDs.
        (#"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "<uuid>"),
        // Anything else numeric, last.
        (#"\d+"#, "<n>"),
    ]

    /// `specs` compiled. A literal that failed to compile would be dropped
    /// here without a sound, so `ThrallIncidentTests` pins that all of them do.
    static let patterns: [(NSRegularExpression, String)] = specs.compactMap { pattern, replacement in
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (expression, replacement)
    }

    /// The fingerprintable form of a log line.
    static func normalise(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // ANSI colour is noise, and a container that colours its errors would
        // otherwise fingerprint differently from one that does not.
        text = stripANSI(text)
        for (expression, replacement) in patterns {
            text = expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: replacement)
        }
        // Collapse **all** whitespace, not just spaces: a log that aligns its
        // columns with tabs would otherwise fingerprint differently from one
        // that uses spaces.
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Bounded: a stack trace on one line would otherwise make the
        // fingerprint the size of the trace.
        return String(text.prefix(200)).lowercased()
    }

    /// The plain text of a line, through the kit's ANSI parser — the same one
    /// the log view renders with, so the two never disagree on what an escape
    /// sequence is.
    static func stripANSI(_ text: String) -> String {
        var parser = AinkradANSIParser()
        return parser.parse(text).map(\.text).joined()
    }

    /// The last line with anything on it — which is where a dying process puts
    /// its reason.
    static func lastMeaningfulLine(of log: String) -> String? {
        log.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
    }
}

/// One problem, however many containers are showing it.
///
/// **This collapse is the product.** 15 crash loops are not 15 problems: on
/// the machine Thrall was designed against, 12 workers were dying on the same
/// `connection refused` — one incident with 12 members. Docker Desktop shows
/// 15 red dots and no thesis; Thrall says "Postgres is refusing connections —
/// 12 containers affected".
struct ThrallIncident: Equatable, Sendable, Identifiable {
    /// `(stack, fingerprint)`. Stack is part of the key because the same error
    /// in two projects is two problems with two different fixes.
    struct Key: Hashable, Sendable {
        let stack: ThrallStackID
        let fingerprint: String
    }

    let key: Key
    let stackName: String
    /// Services showing this problem, ordered by name.
    let services: [String]
    let containerIDs: [String]
    let exitCode: Int?
    /// **The actual error text, never a paraphrase.** The un-normalised line,
    /// because the normalised one is a grouping key and unreadable.
    let evidence: String?
    let imageDigest: String?
    let firstSeen: Date
    let lastSeen: Date
    let restartTotal: Int
    /// `depends_on` targets that are not running — the free verdict.
    let brokenDependencies: [ThrallDependencyVerdict]

    var id: String { "\(key.stack.description)#\(key.fingerprint)" }
    var memberCount: Int { containerIDs.count }

    /// The one-line headline. Names the dependency when there is one, because
    /// "db is exited (1)" is the answer and "12 things are red" is not.
    var headline: String {
        if let verdict = brokenDependencies.first {
            return "\(verdict.dependency) is \(verdict.stateLabel) — "
                + "\(services.count) service\(services.count == 1 ? "" : "s") blocked"
        }
        if let exitCode {
            return "\(services.joined(separator: ", ")) exiting \(exitCode)"
        }
        return services.joined(separator: ", ")
    }
}

/// "`api` depends_on `db`; `db` is `exited (1)`" — comes free from the labels,
/// so it works even for a stack whose compose file is gone.
struct ThrallDependencyVerdict: Equatable, Sendable {
    let dependent: String
    let dependency: String
    let condition: String
    let stateLabel: String

    init(dependent: String, dependency: String, condition: String, stateLabel: String) {
        self.dependent = dependent
        self.dependency = dependency
        self.condition = condition
        self.stateLabel = stateLabel
    }
}

/// Groups crash loops into incidents.
enum ThrallIncidentGrouper {
    /// What the grouper needs per crash-looping service.
    struct Input: Equatable, Sendable {
        let loop: ThrallCrashLoop
        /// The tail of the service's log, if it has been read. Nil is fine —
        /// the fingerprint then rests on exit code and image alone, which
        /// still collapses a fleet of identical workers.
        let logTail: String?
        let imageDigest: String?
        let firstSeen: Date
        let lastSeen: Date

        init(
            loop: ThrallCrashLoop, logTail: String?, imageDigest: String?,
            firstSeen: Date, lastSeen: Date
        ) {
            self.loop = loop
            self.logTail = logTail
            self.imageDigest = imageDigest
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
        }
    }

    /// The fingerprint: exit code + normalised last log line + image digest.
    ///
    /// The image digest is in there because two services running *different*
    /// images that happen to print the same message are not one problem.
    static func fingerprint(exitCode: Int?, logTail: String?, imageDigest: String?) -> String {
        let line =
            logTail.flatMap(ThrallLogFingerprint.lastMeaningfulLine)
            .map(ThrallLogFingerprint.normalise) ?? ""
        return [exitCode.map(String.init) ?? "-", line, imageDigest ?? "-"]
            .joined(separator: "|")
    }

    static func group(
        _ inputs: [Input],
        world: ThrallWorld
    ) -> [ThrallIncident] {
        var buckets: [ThrallIncident.Key: [Input]] = [:]
        for input in inputs {
            let key = ThrallIncident.Key(
                stack: input.loop.stack,
                fingerprint: fingerprint(
                    exitCode: input.loop.exitCode,
                    logTail: input.logTail,
                    imageDigest: input.imageDigest))
            buckets[key, default: []].append(input)
        }

        return buckets.map { key, members in
            let stack = world.stack(key.stack)
            let services = members.map(\.loop.service).uniqued().sorted()
            return ThrallIncident(
                key: key,
                stackName: stack?.displayName ?? key.stack.projectName ?? "Unmanaged",
                services: services,
                containerIDs: members.flatMap(\.loop.containerIDs).uniqued(),
                exitCode: members.first?.loop.exitCode,
                // The real text, un-normalised.
                evidence: members.compactMap(\.logTail)
                    .compactMap(ThrallLogFingerprint.lastMeaningfulLine).first,
                imageDigest: members.first?.imageDigest,
                firstSeen: members.map(\.firstSeen).min() ?? Date(),
                lastSeen: members.map(\.lastSeen).max() ?? Date(),
                restartTotal: members.reduce(0) { $0 + $1.loop.restartCount },
                brokenDependencies: verdicts(for: services, in: stack))
        }
        // Ordered by identity, then size — never by recency, so the list does
        // not reshuffle while the user is reading it.
        .sorted { left, right in
            if left.stackName != right.stackName { return left.stackName < right.stackName }
            return left.id < right.id
        }
    }

    /// Reads `depends_on` off the labels and reports any target that is not
    /// running. No compose file needed, which is why it works on an orphan.
    static func verdicts(for services: [String], in stack: ThrallStack?) -> [ThrallDependencyVerdict] {
        guard let stack else { return [] }
        let byName = Dictionary(uniqueKeysWithValues: stack.services.map { ($0.name, $0) })
        var found: [ThrallDependencyVerdict] = []
        for name in services {
            guard let service = byName[name] else { continue }
            for dependency in service.dependsOn {
                guard let target = byName[dependency.service] else { continue }
                let state = target.worstState
                // A dependency that is absent or not running is the verdict; a
                // running one is not news.
                if let state, state == .running { continue }
                found.append(
                    ThrallDependencyVerdict(
                        dependent: name,
                        dependency: dependency.service,
                        condition: dependency.condition,
                        stateLabel: state?.label.lowercased() ?? "not created"))
            }
        }
        // Deduped on the dependency: twelve workers all blocked on `pgsql` is
        // one verdict, not twelve.
        var seen = Set<String>()
        return found.filter { seen.insert($0.dependency).inserted }
    }
}
