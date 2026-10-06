import AinkradAppKit
import os

/// Thrall's loggers. One subsystem for the host and every plugin (S-LOG-1),
/// so a single Console filter covers them all.
enum Log {
    static let transport = AinkradLog.logger(app: "thrall", area: "transport")
    static let triage = AinkradLog.logger(app: "thrall", area: "triage")
    static let context = AinkradLog.logger(app: "thrall", area: "context")
    static let exec = AinkradLog.logger(app: "thrall", area: "exec")
}
