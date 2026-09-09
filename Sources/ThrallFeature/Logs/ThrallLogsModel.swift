import Foundation
import AinkradAppKit

/// Drives one log pane: which services, following or not, and the buffer.
@MainActor
public final class ThrallLogsModel: ObservableObject {
    @Published public private(set) var buffer = ThrallLogBuffer()
    @Published public var isFollowing = true
    @Published public var filter = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    /// Container ids currently tailed.
    @Published public private(set) var tailing: Set<String> = []

    private var tasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public var visibleLines: [ThrallLogLine] {
        buffer.filtered(filter)
    }

    /// True when more than one service is on the pane, which is when a line
    /// needs to say which service it came from.
    public var showsServicePrefix: Bool { tailing.count > 1 }

    /// Replaces what is being tailed. Cancels anything no longer selected, so
    /// switching stacks does not leave sockets open.
    public func tail(containers: [(id: String, service: String)],
                     read: @escaping @Sendable (String) async throws -> [ThrallLogFrame]) {
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
                        self.buffer.append(frame: frame, service: container.service)
                    }
                    self.buffer.flush()
                    self.isLoading = false
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    self.isLoading = false
                    self.error = "\(error)"
                }
            }
        }
        if containers.isEmpty { isLoading = false }
    }

    public func stop() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        tailing = []
    }

    public func clear() {
        buffer.clear()
    }
}
