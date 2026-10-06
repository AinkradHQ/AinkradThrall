import AinkradAppKit

extension ThrallContainerState {
    /// The one container-state → status colour mapping, used by every badge and ribbon.
    var status: AinkradStatus {
        switch self {
        case .running: return .success
        case .restarting, .dead: return .danger
        case .exited, .unknown: return .warning
        case .created, .paused, .removing: return .neutral
        }
    }
}
