import Foundation
import os

/// Nil-proxy recovery helper, split out of the main coordinator to keep
/// the type body under the SwiftLint line limit. Mirrors
/// `SSHProxyCoordinator.recoverProxyIfNeeded()`.
extension RunProxyCoordinator {
    /// Restarts the Run proxy if it is enabled but currently nil.
    ///
    /// Called by `handleWake()` on the nil-proxy branch. Not part of
    /// `RunProxyDispatching` by design: there is exactly one caller outside
    /// the type and it lives in the same module. Promote deliberately if a
    /// new cross-type caller appears.
    ///
    /// - Returns: `true` if a restart was attempted, `false` if skipped
    ///   (Run disabled, proxy already running, or restart already in flight).
    @discardableResult
    func recoverProxyIfNeeded() async -> Bool {
        guard lastEnabled else { return false }
        guard proxy == nil else { return false }
        guard guardState.beginRestart() else {
            AppLogger.coordinator.debug("run recoverProxyIfNeeded: restart already in flight")
            return false
        }
        defer { guardState.endRestart() }
        AppLogger.coordinator.notice("run recoverProxyIfNeeded: proxy nil, restarting")
        autoHeal = AutoHealStateMachine()
        await startProxy()
        return true
    }
}
