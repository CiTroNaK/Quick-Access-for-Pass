import Foundation
import os

/// Wake-recovery handler, split out of the main coordinator to keep
/// the type body under the SwiftLint line limit.
extension SSHProxyCoordinator {
    /// Called by WakeObserver after the 2-second debounce.
    func handleWake() async {
        AppLogger.coordinator.notice("ssh handleWake")

        if proxy == nil {
            _ = await recoverProxyIfNeeded()
            return
        }

        let listenPath = NSString(string: SSHAgentConstants.defaultProxySocketPath).expandingTildeInPath
        let result = await SSHProxyProbe.listIdentities(at: listenPath)

        let outcome: WakeHandler.ProbeOutcome
        let keyCount: Int
        switch result {
        case .healthy(let count):
            outcome = .healthy
            keyCount = count
        case .emptyIdentities, .unreachable:
            outcome = .unhealthy
            keyCount = 0
        }

        await WakeHandler.handle(
            outcome: outcome,
            callbacks: .init(
                recordHealthy: { [self] in autoHeal.recordHealthy() },
                recordWakeFailure: { [self] in autoHeal.recordWakeFailure(now: Date()) },
                guardBeginRestart: { [self] in guardState.beginRestart() },
                guardEndRestart: { [self] in guardState.endRestart() },
                autoHealBeginRestart: { [self] in autoHeal.beginRestart() },
                autoHealEndRestart: { [self] in autoHeal.endRestart(now: Date()) },
                onHealthy: { [self] in
                    updateSSHHealth(.ok(detail: "\(keyCount) key\(keyCount == 1 ? "" : "s")"))
                },
                onDegraded: { [self] in updateSSHHealth(.degraded(.probeFailed)) },
                onUnreachable: { [self] in updateSSHHealth(.unreachable(.cooldown)) },
                restart: { [self] in
                    AppLogger.coordinator.notice("ssh wake restart triggered")
                    await stopProxy()
                    await startProxy()
                }
            )
        )
    }
}
