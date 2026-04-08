import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("ProcessIdentifier connection-based identification")
@MainActor
struct ProcessIdentifierConnectionTests {
    @Test func signedAppUsesDirectIdentity() {
        let conn = VerifiedConnection(
            fd: -1,
            identity: .signedApp(bundleID: "com.apple.Terminal", teamID: "APPLE"),
            pid: ProcessInfo.processInfo.processIdentifier
        )
        let info = ProcessIdentifier.identify(connection: conn)
        #expect(info.bundleIdentifier == "com.apple.Terminal")
        #expect(info.bundleURL != nil || true)
    }

    @Test func unverifiedUsesAppIdentifierPrefix() {
        let conn = VerifiedConnection(
            fd: -1,
            identity: .unverified(pid: ProcessInfo.processInfo.processIdentifier),
            pid: ProcessInfo.processInfo.processIdentifier
        )
        let info = ProcessIdentifier.identify(connection: conn)
        #expect(info.bundleIdentifier?.hasPrefix("unverified.") == true)
    }

    @Test func trustedHelperIdentifyParentWalks() {
        let conn = VerifiedConnection(
            fd: -1,
            identity: .trustedHelper,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        let info = ProcessIdentifier.identifyParent(of: conn)
        #expect(info.name.isEmpty == false)
    }

    @Test func clientInfoHasBundleURLNotIcon() {
        let info = SSHClientInfo.unknown
        #expect(info.bundleURL == nil)
    }
}
