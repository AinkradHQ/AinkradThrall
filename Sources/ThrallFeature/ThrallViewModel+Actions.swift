import Foundation
import AinkradAppKit

/// The action half of `ThrallViewModel`.
///
/// Split out purely for size — the view model crossed the repo's 500-line
/// limit. The boundary is a real one though: everything here *changes* the
/// machine, while what remains reads it.
@MainActor
extension ThrallViewModel {
    // MARK: - Actions

    /// What a stack can actually be asked to do.
    ///
    /// An **orphaned** stack — config files gone, which is `aai1058` and both
    /// `compose` stacks here — cannot use compose at all: every compose verb
    /// needs the file it was started from. Those stacks get engine-level
    /// container verbs instead, which is what makes them actionable rather
    /// than merely visible.
    public func actions(for stack: ThrallStack) -> [ThrallStackAction] {
        if stack.isConfigMissing {
            return [.engineStart, .engineRestart, .engineStop]
        }
        return [.up, .restart, .pull, .down]
    }

    public func perform(_ action: ThrallStackAction, on stack: ThrallStack) {
        if action == .down, settings.settings.confirmBeforeDown {
            pendingDown = stack
            return
        }
        run(action, on: stack)
    }

    public func confirmPendingDown() {
        guard let stack = pendingDown else { return }
        pendingDown = nil
        run(.down, on: stack)
    }

    public func confirmPendingTeardown() {
        guard let stack = pendingTeardown, let client else { return }
        pendingTeardown = nil
        lastUserAction[stack.id] = Date()
        busyStacks.insert(stack.id)
        Task { [weak self] in
            let outcome = await ThrallOrphanTeardown.run(stack: stack, using: client)
            guard let self else { return }
            self.busyStacks.remove(stack.id)
            self.lastActionMessage = outcome.failures.isEmpty
                ? "Tore down \(stack.displayName) by label — \(outcome.summary)."
                : "Teardown of \(stack.displayName) partly failed: \(outcome.summary)"
            await self.refresh()
        }
    }

    private func run(_ action: ThrallStackAction, on stack: ThrallStack) {
        guard actionTasks[stack.id] == nil else { return }
        // Opens the settle window before the verb runs, so the `die` events it
        // is about to cause are already suppressed when they arrive.
        lastUserAction[stack.id] = Date()
        busyStacks.insert(stack.id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(action, on: stack)
        }
        actionTasks[stack.id] = task
    }

    private func execute(_ action: ThrallStackAction, on stack: ThrallStack) async {
        defer {
            busyStacks.remove(stack.id)
            actionTasks[stack.id] = nil
        }
        do {
            if let verb = action.composeVerb {
                guard let directory = stack.workingDirectoryDisplay,
                      let project = stack.id.projectName else {
                    lastActionMessage = "\(stack.displayName) has no project directory to run in."
                    return
                }
                let command = ThrallComposeCommand(verb: verb,
                                                   projectName: project,
                                                   projectDirectory: directory,
                                                   configFiles: stack.configFiles)
                let result = try await compose.run(command, stack: stack.id,
                                                   dockerHost: dockerHostValue)
                lastActionMessage = result.succeeded
                    ? "\(action.title) finished on \(stack.displayName)."
                    : "\(action.title) failed on \(stack.displayName): \(result.summary)"
            } else if let engineVerb = action.engineVerb {
                try await runEngineVerb(engineVerb, on: stack)
                lastActionMessage = "\(action.title) finished on \(stack.displayName)."
            }
        } catch let error as ThrallProcessError {
            lastActionMessage = Self.describe(error)
        } catch let error as ThrallComposeArgumentGuard.Rejection {
            lastActionMessage = "Refused: \(error.message)"
        } catch let error as ThrallEngineError {
            lastActionMessage = Self.describe(error)
        } catch is CancellationError {
            lastActionMessage = "\(action.title) on \(stack.displayName) was cancelled."
        } catch {
            lastActionMessage = "\(error)"
        }
        await refresh()
    }

    private func runEngineVerb(_ verb: ThrallStackAction.EngineVerb,
                               on stack: ThrallStack) async throws {
        guard let client else { throw ThrallEngineError.noEngineSelected(name: engineLabel) }
        let containers = stack.services.flatMap(\.containers)
        for container in containers {
            switch verb {
            case .start: try await client.start(containerID: container.id)
            case .stop: try await client.stop(containerID: container.id)
            case .restart: try await client.restart(containerID: container.id)
            }
        }
    }

    /// The `DOCKER_HOST` value compose is given, derived from the socket
    /// Thrall is already reading — never a context name.
    private var dockerHostValue: String? {
        guard case .unixSocket(let path) = activeContext?.endpoint else { return nil }
        return "unix://" + path
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
        // Switching engines must not announce every incident on the old one as
        // recovered.
        reporter.reset()
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
            startEventStream(version: version)
            // Skipped in basic mode: the scan reads container logs to fingerprint
            // crash loops, and its only consumers are the triage area and the
            // rail's incident badge — neither of which basic has. Scoped here
            // rather than in the view, because a view cannot decline work a
            // refresh already did.
            if scansForIncidents { await scanForIncidents() }
        } catch let error as ThrallEngineError {
            state = .failed(Self.describe(error))
            host.log.error("Thrall: \(Self.describe(error))")
        } catch let error as ThrallTransportError {
            state = .failed(Self.describe(error, endpoint: context.endpoint))
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: - Events and triage

    /// Starts the events stream once a version is negotiated. Idempotent.
    private func startEventStream(version: ThrallEngineVersion) {
        guard supervisor == nil, case .unixSocket(let path) = activeContext?.endpoint else {
            return
        }
        let engineKey = activeContext?.endpoint.engineKey ?? ""
        let supervisor = ThrallStreamSupervisor(socketPath: path,
                                                apiVersion: version.negotiated)
        self.supervisor = supervisor
        Task {
            // Each handler carries its own `[weak self]`: they outlive the
            // enclosing task and a shared captured `self` var is not sendable
            // into them.
            await supervisor.start(onEvent: { [weak self] event in
                await self?.handle(event, engineKey: engineKey)
            }, onConnected: { [weak self] connected in
                await self?.setEventStreamConnected(connected)
            })
        }
    }

    private func setEventStreamConnected(_ connected: Bool) {
        eventStreamConnected = connected
    }

    /// **An event is an invalidation plus a history append, never a delta.**
    /// One dropped event would otherwise leave the UI permanently wrong, and
    /// the daemon keeps no replay to recover from.
    private func handle(_ event: ThrallEvent, engineKey: String) async {
        triage.record(event, engineKey: engineKey)
        await refresh()
    }

    private func scanForIncidents() async {
        guard let client else { return }
        triage.prune(world: world)
        await triage.scan(
            world: suppressedWorld(),
            inspect: { try await client.inspect(containerID: $0) },
            readLog: { try await client.logTail(containerID: $0) })
        reporter.report(incidents: triage.incidents,
                        suppressedStacks: settlingStacks(),
                        to: host.signals)
    }

    /// Stacks inside their 30 s settle window.
    private func settlingStacks() -> Set<ThrallStackID> {
        let now = Date()
        return Set(lastUserAction.filter { now.timeIntervalSince($0.value) < 30 }.keys)
    }

    /// The world with recently-actioned stacks removed.
    ///
    /// The **30 s settle window**, and it is mandatory rather than polish:
    /// `docker compose up` emits a `die` for every container it recreates, so
    /// without this the user pressing Restart fires a crash-loop incident per
    /// service — which will happen in the first demo.
    private func suppressedWorld() -> ThrallWorld {
        let settling = settlingStacks()
        guard !settling.isEmpty else { return world }
        return ThrallWorld(engineKey: world.engineKey,
                           stacks: world.stacks.filter { !settling.contains($0.id) },
                           generatedAt: world.generatedAt)
    }

    /// Runs a remedy. Only a state-destroying one confirms.
    public func apply(_ remedy: ThrallRemedy, to incident: ThrallIncident) {
        guard let stack = world.stack(incident.key.stack) else { return }
        switch remedy.kind {
        case .restartDependencyThenDependents, .restartServices:
            perform(stack.isConfigMissing ? .engineRestart : .restart, on: stack)
        case .upStack:
            perform(.up, on: stack)
        case .pullStack:
            perform(.pull, on: stack)
        case .teardownByLabel:
            // Confirmed like Down, because it removes containers. Named
            // separately in the dialog so the user knows it goes by label —
            // which is what makes it work where compose cannot.
            pendingTeardown = stack
        }
    }

}
