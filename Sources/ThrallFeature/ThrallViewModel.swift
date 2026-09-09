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

    @Published public private(set) var world: ThrallWorld
    @Published public private(set) var contexts: [ThrallEngineContext] = []
    @Published public private(set) var activeContext: ThrallEngineContext?
    @Published public private(set) var engineVersion: ThrallEngineVersion?
    @Published public private(set) var state: LoadState = .idle
    /// Reasons a context was skipped or overridden, shown in the engine panel.
    @Published public private(set) var contextNotes: [String] = []

    @Published public var selectedStack: ThrallStackID?
    @Published public var expandedStacks: Set<ThrallStackID> = []
    @Published public var expandedServices: Set<String> = []

    private let host: HostServices
    private let settings: ThrallSettingsStore
    private let resolver: ThrallContextResolver
    private var client: ThrallEngineClient?
    private var pollTask: Task<Void, Never>?

    public init(host: HostServices,
                settings: ThrallSettingsStore,
                resolver: ThrallContextResolver = .system()) {
        self.host = host
        self.settings = settings
        self.resolver = resolver
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
        client = nil
    }

    // MARK: - Engine selection

    public func resolveContexts() {
        let resolution = resolver.resolve()
        contexts = resolution.contexts
        contextNotes = resolution.notes
        // Only adopt the resolved context on first run or when it really
        // changed, so a re-resolve cannot silently move the user's selection.
        if activeContext == nil {
            select(resolution.active)
        }
    }

    public func select(_ context: ThrallEngineContext?) {
        activeContext = context
        engineVersion = nil
        client = nil
        guard let context else {
            world = .empty(engineKey: "")
            state = .failed("No engine is selected.")
            return
        }
        world = .empty(engineKey: context.endpoint.engineKey)
        do {
            client = try ThrallEngineClient(endpoint: context.endpoint)
            state = .idle
        } catch let error as ThrallEngineError {
            state = .failed(Self.describe(error))
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: - Reading

    public func refresh() async {
        guard let client, let context = activeContext else { return }
        if case .loaded = state {} else { state = .loading }
        do {
            let version = try await client.version()
            let containers = try await client.containers()
            engineVersion = version
            // Disk candidates arrive with the indexer (Task F); until then the
            // world is engine-only, which is exactly rule 1 of the
            // reconciler's precedence and renders correctly on its own.
            world = ThrallReconciler.reconcile(engineKey: context.endpoint.engineKey,
                                               containers: containers)
            state = .loaded
        } catch let error as ThrallEngineError {
            state = .failed(Self.describe(error))
            host.log.error("Thrall: \(Self.describe(error))")
        } catch let error as ThrallTransportError {
            state = .failed(Self.describe(error, endpoint: context.endpoint))
        } catch {
            state = .failed("\(error)")
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
