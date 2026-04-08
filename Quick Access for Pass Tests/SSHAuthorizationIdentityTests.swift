import Testing
@testable import Quick_Access_for_Pass

@Suite("SSH authorization identity")
struct SSHAuthorizationIdentityTests {
    @Test func requesterIdentityUsesResolvedClientAppInsteadOfPeerIdentity() {
        let connection = VerifiedConnection(
            fd: -1,
            identity: .signedApp(bundleID: "com.fournova.TowerHelper", teamID: "TOWERTEAM"),
            pid: 123
        )
        let clientInfo = SSHClientInfo(
            name: "Tower",
            bundleIdentifier: "com.fournova.Tower",
            bundleURL: nil,
            command: "ssh git@github.com",
            triggerCommand: nil,
            showCommand: false,
            batchMode: false
        )

        let identity = SSHAuthorizationIdentity(connection: connection, clientInfo: clientInfo)

        #expect(identity.requesterAppID == "com.fournova.Tower")
        #expect(identity.peerAppID == "TOWERTEAM.com.fournova.TowerHelper")
        #expect(identity.persistentCacheID == "com.fournova.Tower")
    }

    @Test func terminalPersistentCacheIDUsesRequesterIdentityForCommandScopedRules() {
        let connection = VerifiedConnection(
            fd: -1,
            identity: .unverified(pid: 456),
            pid: 456
        )
        let clientInfo = SSHClientInfo(
            name: "Ghostty",
            bundleIdentifier: "com.mitchellh.ghostty",
            bundleURL: nil,
            command: "ssh git@github.com",
            triggerCommand: "git fetch --all",
            showCommand: true,
            batchMode: false
        )

        let identity = SSHAuthorizationIdentity(connection: connection, clientInfo: clientInfo)

        #expect(identity.requesterAppID == "com.mitchellh.ghostty")
        #expect(identity.peerAppID == "unverified.456")
        #expect(identity.persistentCacheID == "com.mitchellh.ghostty:github.com:git fetch --all")
    }
}
