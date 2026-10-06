import AinkradAppKit
import Foundation

/// Drives one log pane: which services, following or not, and the buffer.
@MainActor
final class ThrallLogsModel: ObservableObject {
    @Published private(set) var buffer = AinkradLogBuffer()
    @Published var isFollowing = true
    @Published var filter = ""
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// Container ids currently tailed.
    @Published private(set) var tailing: Set<String> = []

    private var tasks: [String: Task<Void, Never>] = [:]

    init() {}

    var visibleLines: [AinkradLogLine] {
        buffer.filtered(filter)
    }

    /// True when more than one service is on the pane, which is when a line
    /// needs to say which service it came from.
    var showsServicePrefix: Bool { tailing.count > 1 }

    /// Replaces what is being tailed. Cancels anything no longer selected, so
    /// switching stacks does not leave sockets open.
    func tail(
        containers: [(id: String, service: String)],
        read: @escaping @Sendable (String) async throws -> [ThrallLogFrame]
    ) {
        let wanted = Set(containers.map(\.id))
        for (id, task) in tasks where !wanted.contains(id) {
            task.cancel()
            tasks[id] = nil
        }
        buffer.clear()
        tailing = wanted
        error = nil
        isLoading = !containers.isEmpty

        for container in containers where tasks[container.id] == nil {
            tasks[container.id] = Task { [weak self] in
                do {
                    let frames = try await read(container.id)
                    guard let self, !Task.isCancelled else { return }
                    for frame in frames {
                        self.buffer.append(
                            frame.payload, stream: frame.stream == .stderr ? .stderr : .stdout,
                            source: container.service)
                    }
                    self.buffer.flush()
                    self.isLoading = false
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.isLoading = false
                    self.error = error.localizedDescription
                }
            }
        }
        if containers.isEmpty { isLoading = false }
    }

    func stop() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        tailing = []
    }

    func clear() {
        buffer.clear()
    }
}
