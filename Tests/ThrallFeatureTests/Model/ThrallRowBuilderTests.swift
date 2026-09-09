import Foundation
import Testing
@testable import ThrallFeature

/// The flattening rule, tested without a view — because the ordering property
/// it guarantees is the most consequential one in the app: **rows never
/// reorder on a state change.**
@Suite("ThrallRowBuilder")
struct ThrallRowBuilderTests {
    private static let engineKey = "unix:/tmp/docker.sock"

    private func world() throws -> ThrallWorld {
        let containers = try JSONDecoder().decode(
            [ThrallContainerDTO].self, from: try Fixtures.data(Fixtures.containersAll48))
        return ThrallReconciler.reconcile(engineKey: Self.engineKey, containers: containers)
    }

    private func rows(_ world: ThrallWorld,
                      stacks: Set<ThrallStackID> = [],
                      services: Set<String> = [],
                      showUnmanaged: Bool = true) -> [ThrallRow] {
        ThrallRowBuilder.rows(for: world, expandedStacks: stacks,
                              expandedServices: services, showUnmanaged: showUnmanaged)
    }

    @Test("collapsed, there is exactly one row per stack")
    func collapsed() throws {
        let world = try world()
        let rows = rows(world)
        #expect(rows.count == world.stacks.count)
        #expect(rows.allSatisfy { if case .stack = $0 { return true } else { return false } })
    }

    @Test("expanding a stack adds its services and nothing else")
    func expandStack() throws {
        let world = try world()
        let optimus = try #require(world.stacks.first { $0.displayName == "optimus" })
        let rows = rows(world, stacks: [optimus.id])
        #expect(rows.count == world.stacks.count + optimus.services.count)
        // Services appear directly under their stack, in the stack's order.
        let index = try #require(rows.firstIndex { $0.id == "s:\(optimus.id.description)" })
        let following = rows[(index + 1)...].prefix(optimus.services.count)
        #expect(following.allSatisfy { $0.indentLevel == 1 })
    }

    @Test("expanding a service adds its containers")
    func expandService() throws {
        let world = try world()
        let optimus = try #require(world.stacks.first { $0.displayName == "optimus" })
        let service = try #require(optimus.services.first { !$0.containers.isEmpty })
        let key = ThrallRowBuilder.serviceKey(stack: optimus.id, service: service.name)
        let rows = rows(world, stacks: [optimus.id], services: [key])
        #expect(rows.filter { $0.indentLevel == 2 }.count == service.containers.count)
    }

    /// A service is only unique within its stack — two stacks both having a
    /// `db` is normal, not a collision.
    @Test("service expansion is scoped to its own stack")
    func serviceKeysAreStackScoped() throws {
        let world = try world()
        let names = Set(world.stacks.flatMap { $0.services.map(\.name) })
        let allKeys = world.stacks.flatMap { stack in
            stack.services.map { ThrallRowBuilder.serviceKey(stack: stack.id, service: $0.name) }
        }
        #expect(Set(allKeys).count == allKeys.count)
        #expect(names.count < allKeys.count, "the fixture must actually reuse service names")
    }

    /// **The rule that matters most.** A state change must not move a row: the
    /// list is identity-ordered, so the row ids come back in the same sequence
    /// no matter what the containers are doing.
    @Test("a state change does not reorder rows")
    func stateChangeDoesNotReorder() throws {
        let containers = try JSONDecoder().decode(
            [ThrallContainerDTO].self, from: try Fixtures.data(Fixtures.containersAll48))
        let before = ThrallReconciler.reconcile(engineKey: Self.engineKey, containers: containers)
        // Flip every running container to exited — the worst case for a
        // state-keyed sort.
        let flipped: [ThrallContainerDTO] = try containers.map { dto in
            guard dto.state == "running" else { return dto }
            let labels = try JSONSerialization.data(withJSONObject: dto.labels,
                                                    options: [.sortedKeys])
            let json = """
                {"Id":"\(dto.id)","Names":\(try JSONSerialization
                    .data(withJSONObject: dto.names).jsonText),
                 "Image":"\(dto.image)","State":"exited","Status":"Exited (1) 1 second ago",
                 "Created":\(dto.created),"Labels":\(String(decoding: labels, as: UTF8.self))}
                """
            return try JSONDecoder().decode(ThrallContainerDTO.self, from: Data(json.utf8))
        }
        let after = ThrallReconciler.reconcile(engineKey: Self.engineKey, containers: flipped)

        let expanded = Set(before.stacks.map(\.id))
        let services = Set(before.stacks.flatMap { stack in
            stack.services.map { ThrallRowBuilder.serviceKey(stack: stack.id, service: $0.name) }
        })
        #expect(rows(before, stacks: expanded, services: services).map(\.id)
            == rows(after, stacks: expanded, services: services).map(\.id))
    }

    @Test("hiding unmanaged containers drops only the loose pseudo-stack")
    func hideUnmanaged() throws {
        let world = try world()
        let shown = rows(world, showUnmanaged: true)
        let hidden = rows(world, showUnmanaged: false)
        #expect(shown.count == hidden.count + 1)
        #expect(!hidden.contains { $0.stackID.isLoose })
    }

    @Test("expanding a stack that is not shown adds nothing")
    func expandingHiddenStackIsInert() throws {
        let world = try world()
        let loose = try #require(world.stacks.first { $0.id.isLoose })
        #expect(rows(world, stacks: [loose.id], showUnmanaged: false)
            == rows(world, showUnmanaged: false))
    }

    @Test("row ids are unique, or SwiftUI would drop rows silently")
    func idsAreUnique() throws {
        let world = try world()
        let expanded = Set(world.stacks.map(\.id))
        let services = Set(world.stacks.flatMap { stack in
            stack.services.map { ThrallRowBuilder.serviceKey(stack: stack.id, service: $0.name) }
        })
        let all = rows(world, stacks: expanded, services: services)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.count > 48, "every container plus every service plus every stack")
    }
}

private extension Data {
    var jsonText: String { String(decoding: self, as: UTF8.self) }
}
