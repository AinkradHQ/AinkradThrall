import Foundation
import AinkradAppKit

/// The stacks surface's state, and the only place that decides *when* to talk
/// to the engine.
@MainActor
public final class ThrallViewModel: ObservableObject {
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// Carries the engine's own words where there are any — a paraphrase
        /// is always worse than the original.
        case failed(String)
    }

    @Published public internal(set) var world: ThrallWorld
    @Published public internal(set) var contexts: [ThrallEngineContext] = []
    @Published public internal(set) var activeContext: ThrallEngineContext?
    @Published public internal(set) var engineVersion: ThrallEngineVersion?
    @Published public internal(set) var state: LoadState = .idle
    /// Reasons a context was skipped or overridden, shown in the engine panel.
    @Published public internal(set) var contextNotes: [String] = []

    @Published public var selectedStack: ThrallStackID?
    @Published public var expandedStacks: Set<ThrallStackID> = []
    @Published public var expandedServices: Set<String> = []

    /// A finished action, shown as a toast and then dismissed.
    @Published public var lastActionMessage: String?
    /// Stacks with a compose verb in flight, so a row can show a spinner.
    @Published public internal(set) var busyStacks: Set<ThrallStackID> = []
    /// A pending Down awaiting confirmation. Down destroys state; Restart and
    /// Up never confirm — gating the action that *fixes* a broken service is
    /// what makes people stop using the tool.
    @Published public var pendingDown: ThrallStack?
    /// A pending by-label teardown of an orphaned stack.
    @Published public var pendingTeardown: ThrallStack?

    let host: HostServices
    /// `internal` rather than `private` so `ThrallViewModel+Actions` can
    /// reach it — the type is split across two files only because it crossed
    /// the repo's 500-line limit, and Swift has no file-pair access level.
    let settings: ThrallSettingsStore
    let resolver: ThrallContextResolver
    let compose: ThrallComposeClient
    var client: ThrallEngineClient?
    /// Exposed for the MCP layer, which needs to read logs without going
    /// through a view. Read-only: nothing outside this class may replace it.
    var engineClient: ThrallEngineClient? { client }
    private var pollTask: Task<Void, Never>?
    var actionTasks: [ThrallStackID: Task<Void, Never>] = [:]
    var supervisor: ThrallStreamSupervisor?
    /// The last user action, per stack. Feeds the **30 s settle window**: `up`
    /// legitimately emits a `die` per recreated container, so without it the
    /// user's own Restart button fires a crash-loop alert per service.
    var lastUserAction: [ThrallStackID: Date] = [:]

    /// The triage surface's own model. Public so the shell can hand it to
    /// `TriageView` without the shell owning the scan schedule.
    public let triage = ThrallTriageModel()
    let reporter = ThrallSignalReporter()
    /// The logs area's own model, so its reads are not on the reconcile path.
    public let logs = ThrallLogsModel()
    /// Images, storage and networks. Its `/system/df` read costs 1.86 s, so it
    /// is loaded on demand by its own areas and never by `refresh()`.
    public let storage = ThrallStorageModel()
    @Published public internal(set) var eventStreamConnected = false

    public init(host: HostServices,
                settings: ThrallSettingsStore,
                resolver: ThrallContextResolver = .system(),
                compose: ThrallComposeClient = ThrallComposeClient(
                    runner: ThrallProcessRunner())) {
        self.host = host
        self.settings = settings
        self.resolver = resolver
        self.compose = compose
        self.world = .empty(engineKey: "")
    }

    public var rows: [ThrallRow] {
        ThrallRowBuilder.rows(for: world,
                              expandedStacks: expandedStacks,
                              expandedServices: expandedServices,
                              showUnmanaged: settings.settings.showUnmanaged)
    }

    /// What the engine chip reads. The context name, not the socket path —
    /// `orbstack` is what the user recognises.
    public var engineLabel: String { activeContext?.name ?? "No engine" }

    // MARK: - Lifecycle

    public func bootstrap() {
        guard case .idle = state else { return }
        resolveContexts()
        Task { await refresh() }
    }

    /// The self-healing floor: poll **as well as** invalidating on events.
    ///
    /// An events socket dies silently when the engine restarts, and a purely
    /// event-driven UI then freezes on stale state with nothing to say so. The
    /// poll is what guarantees the screen converges on the truth even when
    /// every other mechanism has failed.
    public func startPolling() {
        guard pollTask == nil else { return }
        let seconds = settings.settings.effectivePollSeconds
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    public func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        // The one long-lived socket in the app. An uncancelled `NWConnection`
        // keeps a socket *and* a dispatch source alive, so this is not
        // optional.
        let supervisor = self.supervisor
        self.supervisor = nil
        Task { await supervisor?.stop() }
        // Cancelling an action task sends SIGINT then SIGKILL to its compose
        // process — see `ThrallProcessRunner`. Leaving them running would keep
        // spawning containers after the window closed.
        for task in actionTasks.values { task.cancel() }
        actionTasks = [:]
        logs.stop()
        client = nil
    }

    /// Points the logs pane at a set of containers.
    ///
    /// Lives here rather than in `ThrallLogsModel` because the engine client
    /// is the view model's, and a log read is the one place where handing the
    /// client out would let a view open a socket.
    public func tailLogs(_ containers: [(id: String, service: String)],
                         into logs: ThrallLogsModel) async {
        guard let client else {
            logs.tail(containers: [], read: { _ in [] })
            return
        }
        logs.tail(containers: containers) { id in
            try await client.logs(containerID: id, tail: 400)
        }
    }

    // MARK: - Row interaction

    public func toggle(stack id: ThrallStackID) {
        if expandedStacks.contains(id) {
            expandedStacks.remove(id)
        } else {
            expandedStacks.insert(id)
        }
    }

    public func toggle(service name: String, in stack: ThrallStackID) {
        let key = ThrallRowBuilder.serviceKey(stack: stack, service: name)
        if expandedServices.contains(key) {
            expandedServices.remove(key)
        } else {
            expandedServices.insert(key)
        }
    }

    public func isExpanded(service name: String, in stack: ThrallStackID) -> Bool {
        expandedServices.contains(ThrallRowBuilder.serviceKey(stack: stack, service: name))
    }

    // MARK: - Messages

    // `nonisolated` because both are pure string mapping — the view model's
    // isolation is about its published state, not about phrasing an error.
    nonisolated static func describe(_ error: ThrallProcessError) -> String {
        switch error {
        case .binaryNotFound(let message): return message
        case .launchFailed(let detail): return "Could not launch docker: \(detail)"
        case .rejected(let message): return "Refused: \(message)"
        case .cancelled: return "The command was cancelled."
        }
    }

    nonisolated static func describe(_ error: ThrallEngineError) -> String {
        switch error {
        case .unsupportedEndpoint(let reason):
            return "This engine cannot be used: \(reason)."
        case .noEngineSelected(let name):
            return "The context \(name) is not in the Docker context store."
        case .versionUnreadable(let detail):
            return "The engine did not report a usable API version (\(detail))."
        case .apiTooOld(let reported, let minimum):
            return "This engine speaks API \(reported); Thrall needs \(minimum) or newer."
        case .apiNotServable(let chosen, let serverMinimum):
            return "The engine will not serve API \(chosen) (its minimum is \(serverMinimum))."
        case .http(let status, let message):
            return "The engine returned \(status): \(message)"
        case .decoding(let type, _):
            return "The engine sent a \(type) Thrall could not read."
        }
    }

    /// Turns a transport failure into a sentence about the machine.
    ///
    /// The socket-missing case is the one that matters, because it is the
    /// normal state of a configured-but-stopped engine — `desktop-linux` is
    /// exactly this on the machine Thrall was built on. Network.framework
    /// reports it as `POSIXErrorCode(rawValue: 2)`, which is true, useless,
    /// and exactly the kind of raw framework text that should never reach a
    /// window. Naming the socket instead tells the user which engine to start.
    nonisolated static func describe(_ error: ThrallTransportError,
                                     endpoint: ThrallEngineEndpoint?) -> String {
        let socket: String
        if case .unixSocket(let path) = endpoint {
            socket = ThrallPathDisplay.abbreviate(path, maxLength: 44)
        } else {
            socket = "the engine socket"
        }
        switch error {
        case .connectionFailed(let detail) where Self.meansNothingIsListening(detail):
            return "Nothing is listening at \(socket). Start the engine and try again."
        case .notConnected, .closed:
            return "The engine stopped responding."
        case .timedOut:
            return "The engine did not answer in time."
        case .connectionFailed(let detail):
            return "Could not reach \(socket): \(detail)"
        case .malformedResponse, .tooLarge, .unsupportedFraming:
            return "The engine sent something Thrall could not read."
        case .invalidRequest(let detail):
            return "Thrall built an invalid request: \(detail)"
        }
    }

    /// ENOENT (no socket file) and ECONNREFUSED (file there, daemon gone) are
    /// the same thing to a user: the engine is not running.
    nonisolated private static func meansNothingIsListening(_ detail: String) -> Bool {
        detail.contains("No such file or directory")
            || detail.contains("Connection refused")
            || detail.contains("rawValue: 2)")
            || detail.contains("rawValue: 61)")
    }
}
