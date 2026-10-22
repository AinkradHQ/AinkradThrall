import Foundation

// thrall-engine — owns the Linux VM behind Thrall's own engine.
//
//   thrall-engine run [--image-dir DIR]
//
// Runs in the foreground until SIGTERM or SIGINT, then shuts the guest down
// gracefully. launchd starts it in E3; until then it is started by hand.

let usage = "usage: thrall-engine run [--image-dir DIR]\n"

func log(_ message: String) {
    FileHandle.standardError.write(Data("thrall-engine: \(message)\n".utf8))
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "run" else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}
arguments.removeFirst()
var imageDirectory: URL?
while let flag = arguments.first {
    arguments.removeFirst()
    guard flag == "--image-dir", let value = arguments.first else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(64)
    }
    arguments.removeFirst()
    imageDirectory = URL(fileURLWithPath: value)
}

let paths = ThrallEnginePaths.user(imageDirectory: imageDirectory)

// A write to a socket whose peer has gone must fail with EPIPE, not kill the
// helper and every container connection with it.
signal(SIGPIPE, SIG_IGN)

let services = ThrallEngineServices(paths: paths, log: log)
do {
    try services.start()
} catch {
    log("cannot serve \(services.dockerSocketPath): \(error)")
    exit(1)
}

var currentMachine: ThrallVZMachine?
let supervisor = ThrallEngineSupervisor {
    // Read before every boot, so a size change in Settings applies on the
    // next restart without restarting the helper.
    let spec = ThrallVMSpec.resolved(config: ThrallEngineConfig.read(from: paths.configFile))
    let console = try ThrallEngineDisk.openConsoleLog(at: paths.consoleLog)
    let configuration = try ThrallVZConfiguration.make(spec: spec, paths: paths, console: console)
    let machine = ThrallVZMachine(configuration: configuration, console: console)
    currentMachine = machine
    return machine
}
// status.json: what the plugin's engine panel reads. Rewritten on every
// change; removed on a clean exit, so a missing file means no helper.
var status = ThrallEngineStatus(phase: .starting)
/// Set once the helper has stopped cleanly: the last port teardown must not
/// write back the file that a clean exit just removed.
var statusRetired = false
@MainActor func publishStatus() {
    guard !statusRetired else { return }
    status.forwardedPorts = services.forwardedPorts
    status.conflictedPorts = services.conflictedPorts
    do {
        try status.write(to: paths.statusFile)
    } catch {
        log("cannot write \(paths.statusFile.path): \(error)")
    }
}
services.onPortsChanged = { publishStatus() }

supervisor.onStateChange = { state in
    log("\(state)")
    if state == .running, let currentMachine {
        services.machineDidStart(currentMachine)
    } else if state != .running {
        services.machineDidStop()
    }
    switch state {
    case .idle, .starting: status = ThrallEngineStatus(phase: .starting)
    case .running: status = ThrallEngineStatus(phase: .running, runningSince: Date())
    case .stopping: status.phase = .stopping
    case .backingOff(let delay):
        status = ThrallEngineStatus(phase: .restarting, retryInSeconds: Int(delay.components.seconds))
    case .failed(let reason): status = ThrallEngineStatus(phase: .failed, failure: reason)
    case .stopped:
        statusRetired = true
        try? FileManager.default.removeItem(at: paths.statusFile)
        return
    }
    publishStatus()
}

// Signals are handled by dispatch sources, so the default handlers must not
// kill the process first.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            Task { await supervisor.shutdown() }
        }
    }
    source.resume()
    signalSources.append(source)
}

Task { @MainActor in
    await supervisor.run()
    services.stop()
    if case .failed(let reason) = supervisor.state {
        // The failed status outlives the helper: launchd does not restart a
        // configuration error, and the panel needs to say why.
        publishStatus()
        log(reason)
        exit(78)  // EX_CONFIG: launchd must not restart a broken configuration.
    }
    exit(0)
}

dispatchMain()
