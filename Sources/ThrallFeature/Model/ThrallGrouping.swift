import Foundation

/// The slot the Project layer lands in, kept **beside** the world rather than
/// inside it.
///
/// A `projectID` field on `ThrallStack` would force `ThrallReconciler` — a
/// pure function over engine and disk facts — to take user-authored data as an
/// input, and the reconciler's purity is what makes the whole model testable
/// from a JSON file. So grouping is a separate map, persisted in
/// `host.documents`, and the view model exposes `groups` from day one.
///
/// In v1 every stack lands in one implicit group, so views are written against
/// a two-level tree already and the Project milestone adds a resolver and an
/// editor rather than a re-shape.
public struct ThrallGrouping: Equatable, Sendable, Codable {
    public static let implicitGroupName = "All stacks"

    /// Stack identity string -> project name. Keyed by
    /// `ThrallStackID.description` because that is the only stable, encodable
    /// spelling of the identity.
    public var assignments: [String: String]

    public init(assignments: [String: String] = [:]) {
        self.assignments = assignments
    }

    public func groupName(for id: ThrallStackID) -> String {
        assignments[id.description] ?? Self.implicitGroupName
    }

    public mutating func assign(_ id: ThrallStackID, to group: String?) {
        if let group, !group.isEmpty {
            assignments[id.description] = group
        } else {
            assignments.removeValue(forKey: id.description)
        }
    }
}

/// One level of the tree the stacks list renders.
public struct ThrallStackGroup: Equatable, Sendable, Identifiable {
    public let name: String
    public let stacks: [ThrallStack]

    public var id: String { name }

    public init(name: String, stacks: [ThrallStack]) {
        self.name = name
        self.stacks = stacks
    }
}

extension ThrallWorld {
    /// The two-level tree, which in v1 is one group holding everything.
    public func groups(using grouping: ThrallGrouping = ThrallGrouping()) -> [ThrallStackGroup] {
        var buckets: [String: [ThrallStack]] = [:]
        var order: [String] = []
        for stack in stacks {
            let name = grouping.groupName(for: stack.id)
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(stack)
        }
        return order.sorted().map { ThrallStackGroup(name: $0, stacks: buckets[$0] ?? []) }
    }
}
