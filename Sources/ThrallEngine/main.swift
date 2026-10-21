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
let spec = ThrallVMSpec.defaults()

let supervisor = ThrallEngineSupervisor {
    let console = try ThrallEngineDisk.openConsoleLog(at: paths.consoleLog)
    let configuration = try ThrallVZConfiguration.make(spec: spec, paths: paths, console: console)
    return ThrallVZMachine(configuration: configuration, console: console)
}
supervisor.onStateChange = { log("\($0)") }

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
    if case .failed(let reason) = supervisor.state {
        log(reason)
        exit(78)  // EX_CONFIG: launchd must not restart a broken configuration.
    }
    exit(0)
}

dispatchMain()
