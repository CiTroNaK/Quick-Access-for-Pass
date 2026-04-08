import Foundation

@MainActor
extension SSHProxyCoordinator {
    func authorizeProxyRequest(
        keyBlob: Data,
        connection: VerifiedConnection,
        authController: SSHAuthWindowController
    ) async -> SSHAuthorizationResult {
        var lockToken: UUID?
        defer {
            if let token = lockToken {
                clearPendingLockContext(token)
            }
        }

        if isAppLocked() {
            let clientInfo = ProcessIdentifier.identifyRequester(of: connection)
            let host = clientInfo.command.flatMap(ProcessIdentifier.parseHost)
            let keySummary = SSHKeyNameCache.shared.name(for: keyBlob)
            let context = PendingLockContext.ssh(
                appName: clientInfo.name,
                host: host,
                keySummary: keySummary
            )
            lockToken = setPendingLockContext(context)
            guard let showPanel = showLockedPanel else { return .deny }
            let unlocked = await showPanel()
            guard unlocked else { return .deny }
        }

        return await authController.authorize(keyBlob: keyBlob, connection: connection)
    }
}
