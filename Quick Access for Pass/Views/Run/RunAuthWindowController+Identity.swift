import AppKit

extension RunAuthWindowController {
    struct ResolvedIdentity {
        let clientInfo: SSHClientInfo
        let appIdentifier: String
        let appTeamID: String?
    }

    func resolveIdentity(
        for connection: VerifiedConnection,
        profile: String
    ) -> ResolvedIdentity? {
        if case .unverified = connection.identity {
            logDecision(appIdentifier: "unverified.\(connection.pid)", profile: profile,
                        matchType: "none", allowed: false, source: "rejected")
            return nil
        }
        switch connection.identity {
        case .trustedHelper:
            let parentInfo = identifyParent(connection)
            return ResolvedIdentity(
                clientInfo: parentInfo,
                appIdentifier: parentInfo.bundleIdentifier ?? "unknown",
                appTeamID: nil
            )

        case .signedApp(let bundleID, let teamID):
            let runningApp = NSRunningApplication(processIdentifier: connection.pid)
            return ResolvedIdentity(
                clientInfo: SSHClientInfo(name: runningApp?.localizedName ?? bundleID,
                                          bundleIdentifier: bundleID, bundleURL: runningApp?.bundleURL,
                                          command: nil, triggerCommand: nil, showCommand: false, batchMode: false),
                appIdentifier: connection.identity.appIdentifier ?? bundleID,
                appTeamID: teamID
            )

        case .unverified:
            return nil
        }
    }
}
