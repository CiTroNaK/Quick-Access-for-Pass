import Foundation

nonisolated struct SSHAuthorizationIdentity: Sendable {
    let requesterAppID: String
    let peerAppID: String?
    let appTeamID: String?
    let persistentCacheID: String

    init(connection: VerifiedConnection, clientInfo: SSHClientInfo) {
        let requesterAppID = clientInfo.bundleIdentifier ?? clientInfo.name
        self.requesterAppID = requesterAppID
        self.peerAppID = connection.identity.appIdentifier
        self.appTeamID = connection.identity.teamID

        let host = clientInfo.command.flatMap(ProcessIdentifier.parseHost)
        if clientInfo.showCommand, let host {
            if let trigger = clientInfo.triggerCommand {
                persistentCacheID = "\(requesterAppID):\(host):\(trigger)"
            } else {
                persistentCacheID = "\(requesterAppID):\(host)"
            }
        } else {
            persistentCacheID = requesterAppID
        }
    }
}
