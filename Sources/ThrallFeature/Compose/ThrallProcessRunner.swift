import Foundation

public struct ThrallProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let outputWasTruncated: Bool

    public var succeeded: Bool { exitCode == 0 }

    /// The engine's or compose's own last words, for a toast. Prefers stderr,
    /// which is where compose writes progress and failures.
    public var summary: String {
        let source = standardError.isEmpty ? standardOutput : standardError
        return source.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}

public enum ThrallProcessError: Error, Equatable, Sendable {
    case binaryNotFound(String)
    case launchFailed(String)
    case rejected(String)
    case cancelled
}

/// Spawns `docker` and collects its output.
///
/// Copies `GitRepositoryClient`'s shape, including the bug it documents:
/// **both pipes are drained on background queues BEFORE `waitUntilExit()`.**
/// Read them after and the child blocks writing once it fills the ~64 KB pipe
/// buffer, the parent blocks waiting for a child that can never exit, and the
/// actor dies with it. `docker compose up` on `aai1058`'s 24 services goes far
/// past 64 KB, so this is the normal path here, not an edge case.
public struct ThrallProcessRunner: Sendable {
    public static let maximumOutputBytes = 4 * 1_048_576
    public static let maximumErrorBytes = 1_048_576

    private static let queue = DispatchQueue(label: "com.ainkrad.thrall.process",
                                             attributes: .concurrent)

    public var binary: ThrallDockerBinary
    public var environment: [String: String]

    public init(binary: ThrallDockerBinary = ThrallDockerBinary(),
                environment: [String: String] = [:]) {
        self.binary = binary
        self.environment = environment
    }

    /// Runs `docker <arguments>`, cancellable.
    ///
    /// Cancellation sends **SIGINT, then SIGKILL** — compose traps SIGINT and
    /// unwinds cleanly (leaving a consistent stack), and only a process that
    /// ignores it gets killed. Killing first would leave half-created
    /// containers behind.
    public func run(_ arguments: [String],
                    workingDirectory: String? = nil,
                    graceSeconds: Double = 3) async throws -> ThrallProcessResult {
        if let rejection = ThrallComposeArgumentGuard.rejection(in: arguments) {
            throw ThrallProcessError.rejected(rejection.message)
        }
        guard let executable = binary.resolve() else {
            throw ThrallProcessError.binaryNotFound(binary.notFoundMessage)
        }
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    do {
                        let result = try Self.runBlocking(executable: executable,
                                                          arguments: arguments,
                                                          workingDirectory: workingDirectory,
                                                          environment: environment,
                                                          handle: handle)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            handle.interruptThenKill(after: graceSeconds)
        }
    }

    /// The blocking spawn. `nonisolated static` so it cannot touch any actor's
    /// state by accident.
    private nonisolated static func runBlocking(executable: String,
                                                arguments: [String],
                                                workingDirectory: String?,
                                                environment: [String: String],
                                                handle: ProcessHandle) throws -> ThrallProcessResult {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errorOutput
        // Compose reads nothing from stdin here, and leaving it inherited lets
        // a prompt block forever with no terminal to answer it.
        process.standardInput = FileHandle.nullDevice
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged

        do {
            try process.run()
        } catch {
            throw ThrallProcessError.launchFailed("\(error.localizedDescription)")
        }
        handle.adopt(process)

        // BEFORE waitUntilExit — see the type's documentation.
        let outDrain = PipeDrain(handle: output.fileHandleForReading, limit: maximumOutputBytes)
        let errDrain = PipeDrain(handle: errorOutput.fileHandleForReading, limit: maximumErrorBytes)
        outDrain.start()
        errDrain.start()

        process.waitUntilExit()
        let (outData, outTruncated) = outDrain.finish()
        let (errData, _) = errDrain.finish()
        handle.release()

        return ThrallProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            outputWasTruncated: outTruncated)
    }
}

/// Lets the cancellation handler reach a process the spawn queue owns.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        // Already cancelled before the spawn finished: interrupt immediately
        // rather than let it run detached.
        if cancelled {
            process.interrupt()
            return
        }
        self.process = process
    }

    func release() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func interruptThenKill(after grace: Double) {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak running] in
            guard let running, running.isRunning else { return }
            running.terminate()
        }
    }
}

/// Reads one end of a pipe to EOF on a background queue.
///
/// `limit` bounds what is retained; bytes past it are read and **discarded**,
/// not left in the pipe — the deadlock returns the moment anything stops
/// reading.
private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let queue: DispatchQueue
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(handle: FileHandle, limit: Int) {
        self.handle = handle
        self.limit = limit
        self.queue = DispatchQueue(label: "com.ainkrad.thrall.pipe-drain")
    }

    func start() {
        queue.async(group: group) { [self] in
            while true {
                // `availableData` returns empty exactly at EOF.
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if data.count < limit {
                    let room = limit - data.count
                    data.append(chunk.count <= room ? chunk : chunk.prefix(room))
                    if chunk.count > room { truncated = true }
                } else {
                    truncated = true
                }
                lock.unlock()
            }
        }
    }

    func finish() -> (Data, Bool) {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }
}
