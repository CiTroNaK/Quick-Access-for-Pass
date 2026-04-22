import AppKit

extension RunAuthWindowController {
    struct ResolvedIdentity {
        let appName: String
        let appBundleURL: URL?
        let appIdentifier: String
        let appTeamID: String?
    }

    func resolveIdentity(
        for connection: VerifiedConnection,
        profile: String
    ) -> ResolvedIdentity? {
        switch connection.identity {
        case .trustedHelper:
            let parentInfo = ProcessIdentifier.identifyParent(of: connection)
            return ResolvedIdentity(
                appName: parentInfo.name,
                appBundleURL: parentInfo.bundleURL,
                appIdentifier: parentInfo.bundleIdentifier ?? "unknown",
                appTeamID: nil
            )

        case .signedApp(let bundleID, let teamID):
            let runningApp = NSRunningApplication(processIdentifier: connection.pid)
            return ResolvedIdentity(
                appName: runningApp?.localizedName ?? bundleID,
                appBundleURL: runningApp?.bundleURL,
                appIdentifier: connection.identity.appIdentifier ?? bundleID,
                appTeamID: teamID
            )

        case .unverified:
            logDecision(
                appIdentifier: "unverified.\(connection.pid)",
                profile: profile,
                command: "",
                allowed: false,
                source: "rejected"
            )
            return nil
        }
    }
}
