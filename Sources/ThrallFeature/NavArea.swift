import Foundation

/// Thrall's areas.
///
/// Deliberately **not** Docker Desktop's object-type taxonomy (Containers /
/// Images / Volumes / Builds). That taxonomy fails on a real machine: 48
/// containers across 5 compose projects is 48 rows the user never thinks in,
/// and the most valuable surface — what is broken right now — is not a
/// destination there at all, only a filter on a list.
public enum NavArea: String, CaseIterable, Identifiable, Sendable {
    /// What is wrong right now. First, and the only area that carries a badge.
    case triage
    /// Compose projects. The core object, and the default landing area.
    case stacks
    /// Flat escape hatch — containers belonging to no recognisable project.
    case containers
    /// Cross-stack tailing. Its own area because "what happened at 14:32
    /// across two stacks" cannot be answered inside one stack.
    case logs
    case images
    /// Volumes, build cache, networks and reclaim. One story ("give me my disk
    /// back") that would otherwise wear three nouns.
    case storage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .triage: return "Triage"
        case .stacks: return "Stacks"
        case .containers: return "Containers"
        case .logs: return "Logs"
        case .images: return "Images"
        case .storage: return "Storage"
        }
    }

    /// SF Symbol name, tinted from the host theme at the call site.
    public var icon: String {
        switch self {
        case .triage: return "exclamationmark.triangle"
        case .stacks: return "square.stack.3d.up"
        case .containers: return "cube"
        case .logs: return "text.alignleft"
        case .images: return "opticaldiscdrive"
        case .storage: return "internaldrive"
        }
    }

    public static var built: [NavArea] { allCases }
}
