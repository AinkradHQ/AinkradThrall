import Foundation

/// Fires its body at most once, whoever calls it and from wherever.
///
/// Lifted from `AinkradRaven`'s `LoopbackCallbackListener`, where it exists
/// because that file shipped a leaked continuation once. Every suspended call
/// in `ThrallConnection` resumes through one of these, so a callback arriving
/// after a timeout — or after `close()`, or after task cancellation — is a
/// no-op rather than a double resume, which is a crash and not a bug you get
/// to debug later.
final class ThrallOneShotResumeGuard<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private let onFirstFire: (Value) -> Void

    init(onFirstFire: @escaping (Value) -> Void) {
        self.onFirstFire = onFirstFire
    }

    @discardableResult
    func fire(_ value: Value) -> Bool {
        lock.lock()
        let shouldFire = !hasFired
        if shouldFire { hasFired = true }
        lock.unlock()
        if shouldFire { onFirstFire(value) }
        return shouldFire
    }
}
