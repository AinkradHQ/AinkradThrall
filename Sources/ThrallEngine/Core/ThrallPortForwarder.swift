import Foundation

/// Something that stops listening when asked. `ThrallSocket` in production.
protocol ThrallStoppable: AnyObject {
    func stop()
}

extension ThrallSocket: ThrallStoppable {}

/// Mirrors the guest's published TCP ports on `127.0.0.1`.
///
/// It reconciles a wanted set against what is open: new ports open, ports no
/// container publishes any more close. A port that is already taken on the
/// Mac is reported once and retried on the next reconcile. It is never
/// silently skipped.
@MainActor
final class ThrallPortForwarder {
    private let open: (Int) throws -> any ThrallStoppable
    private let report: (String) -> Void
    private(set) var listeners: [Int: any ThrallStoppable] = [:]
    private(set) var conflicts: Set<Int> = []

    init(open: @escaping (Int) throws -> any ThrallStoppable, report: @escaping (String) -> Void) {
        self.open = open
        self.report = report
    }

    /// The request that lists running containers. HTTP/1.0, so `dockerd`
    /// closes the connection after the response and reading to EOF is the
    /// whole parser.
    nonisolated static let containersRequest = Data("GET /containers/json HTTP/1.0\r\nHost: docker\r\n\r\n".utf8)

    /// The TCP host ports published by the containers in a
    /// `/containers/json` response. Docker lists one row per address family,
    /// so a port appears twice; the set collapses that.
    nonisolated static func wanted(fromResponse response: Data) -> Set<Int>? {
        guard let split = response.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let statusLine = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        guard statusLine.split(separator: " ").dropFirst().first == "200",
            let containers = try? JSONDecoder().decode([Container].self, from: response[split.upperBound...])
        else { return nil }
        return Set(containers.flatMap(\.ports).compactMap { $0.type == "tcp" ? $0.publicPort : nil })
    }

    private struct Container: Decodable {
        let ports: [Port]

        enum CodingKeys: String, CodingKey {
            case ports = "Ports"
        }
    }

    private struct Port: Decodable {
        let publicPort: Int?
        let type: String

        enum CodingKeys: String, CodingKey {
            case publicPort = "PublicPort"
            case type = "Type"
        }
    }

    func reconcile(_ wanted: Set<Int>) {
        for (port, listener) in listeners where !wanted.contains(port) {
            listener.stop()
            listeners[port] = nil
        }
        conflicts.formIntersection(wanted)
        for port in wanted.sorted() where listeners[port] == nil {
            do {
                listeners[port] = try open(port)
                conflicts.remove(port)
            } catch {
                if conflicts.insert(port).inserted {
                    report("cannot forward localhost:\(port): \(error)")
                }
            }
        }
    }

    func stopAll() {
        reconcile([])
    }
}

/// Finds the guest's IP in the NAT DHCP server's lease file.
///
/// The lease file writes each MAC octet without its leading zero and prefixes
/// a hardware type (`1,2e:1:3f:…`), so both sides are normalised before they
/// are compared. Newest leases come first, so the first match wins.
enum ThrallDHCPLeases {
    static let path = "/var/db/dhcpd_leases"

    static func address(forMAC mac: String, in contents: String) -> String? {
        let wanted = normalise(mac)
        var address: String?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                address = nil
            } else if line.hasPrefix("ip_address=") {
                address = String(line.dropFirst("ip_address=".count))
            } else if line.hasPrefix("hw_address=") {
                let value = line.dropFirst("hw_address=".count)
                let hardware = value.split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
                if normalise(hardware) == wanted, let address { return address }
            }
        }
        return nil
    }

    private static func normalise(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { octet in
            UInt8(octet, radix: 16).map { String($0, radix: 16) } ?? String(octet)
        }.joined(separator: ":")
    }
}
