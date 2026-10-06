import Foundation

/// A verb a stack row can offer.
///
/// Split into compose verbs and engine verbs because an **orphaned** stack can
/// only use the latter: every compose verb needs the file the stack was
/// started from, and `aai1058`'s files are gone. Without the engine half, the
/// largest broken stack on this machine would be visible and untouchable.
enum ThrallStackAction: String, Equatable, Sendable, CaseIterable, Identifiable {
    case up, restart, pull, down
    case engineStart, engineStop, engineRestart

    var id: String { rawValue }

    var composeVerb: ThrallComposeCommand.Verb? {
        switch self {
        case .up: return .up
        case .restart: return .restart
        case .pull: return .pull
        case .down: return .down
        case .engineStart, .engineStop, .engineRestart: return nil
        }
    }

    enum EngineVerb: Equatable, Sendable { case start, stop, restart }

    var engineVerb: EngineVerb? {
        switch self {
        case .engineStart: return .start
        case .engineStop: return .stop
        case .engineRestart: return .restart
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .up: return "Up"
        case .restart, .engineRestart: return "Restart"
        case .pull: return "Pull"
        case .down: return "Down"
        case .engineStart: return "Start"
        case .engineStop: return "Stop"
        }
    }

    var icon: String {
        switch self {
        case .up, .engineStart: return "play.fill"
        case .restart, .engineRestart: return "arrow.clockwise"
        case .pull: return "arrow.down.circle"
        case .down, .engineStop: return "stop.fill"
        }
    }
}
