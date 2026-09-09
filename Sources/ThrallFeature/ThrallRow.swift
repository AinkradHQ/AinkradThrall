import Foundation

/// One row in the stacks list — **flattened**, never nested.
///
/// This is a virtualization requirement, not a style preference. `LazyVStack`
/// only defers its *direct* children, so a `ForEach` of stacks each containing
/// a `ForEach` of services materialises all 24 of `aai1058`'s children the
/// instant it expands, while still passing the repo's
/// `check-virtualization.sh` regex. Flattening to one array of leaf rows is
/// what makes the laziness real.
public enum ThrallRow: Identifiable, Hashable, Sendable {
    case stack(ThrallStack)
    case service(stack: ThrallStackID, service: ThrallService)
    case container(stack: ThrallStackID, service: String, container: ThrallContainer)

    public var id: String {
        switch self {
        case .stack(let stack):
            return "s:\(stack.id.description)"
        case .service(let stack, let service):
            return "v:\(stack.description)/\(service.name)"
        case .container(let stack, let service, let container):
            return "c:\(stack.description)/\(service)/\(container.id)"
        }
    }

    public var indentLevel: Int {
        switch self {
        case .stack: return 0
        case .service: return 1
        case .container: return 2
        }
    }

    public var stackID: ThrallStackID {
        switch self {
        case .stack(let stack): return stack.id
        case .service(let stack, _): return stack
        case .container(let stack, _, _): return stack
        }
    }
}

/// Flattens the world into rows, honouring what is expanded.
///
/// A pure function, so the ordering rule that matters most in this app is
/// testable without a view: **rows never reorder on a state change.** The
/// world arrives already sorted by identity, and nothing here re-sorts.
public enum ThrallRowBuilder {
    public static func rows(for world: ThrallWorld,
                            expandedStacks: Set<ThrallStackID>,
                            expandedServices: Set<String>,
                            showUnmanaged: Bool) -> [ThrallRow] {
        var rows: [ThrallRow] = []
        for stack in world.stacks {
            if stack.id.isLoose && !showUnmanaged { continue }
            rows.append(.stack(stack))
            guard expandedStacks.contains(stack.id) else { continue }
            for service in stack.services {
                rows.append(.service(stack: stack.id, service: service))
                let key = serviceKey(stack: stack.id, service: service.name)
                guard expandedServices.contains(key) else { continue }
                for container in service.containers {
                    rows.append(.container(stack: stack.id, service: service.name,
                                           container: container))
                }
            }
        }
        return rows
    }

    /// A service is only unique within its stack — two stacks both having a
    /// `db` service is the normal case, not a collision.
    public static func serviceKey(stack: ThrallStackID, service: String) -> String {
        "\(stack.description)/\(service)"
    }
}
