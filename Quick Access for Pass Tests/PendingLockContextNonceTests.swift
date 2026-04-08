import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("AppDelegate pending lock context nonce")
@MainActor
struct PendingLockContextNonceTests {

    @Test func clearWithMatchingTokenClearsContext() {
        let delegate = AppDelegate()
        let token = delegate.setPendingLockContext(
            .ssh(appName: "Terminal", host: nil, keySummary: nil)
        )

        #expect(delegate.pendingLockContext != nil)

        delegate.clearPendingLockContext(token: token)
        #expect(delegate.pendingLockContext == nil)
    }

    @Test func clearWithStaleTokenIsNoop() {
        let delegate = AppDelegate()
        let firstToken = delegate.setPendingLockContext(
            .ssh(appName: "Terminal", host: nil, keySummary: nil)
        )
        _ = delegate.setPendingLockContext(
            .run(appName: "qa-run", profileName: "Prod", commandSummary: nil)
        )

        delegate.clearPendingLockContext(token: firstToken)

        #expect(delegate.pendingLockContext?.kind == .run)
    }

    @Test func clearWithMatchingSecondTokenClearsSuccessfully() {
        let delegate = AppDelegate()
        _ = delegate.setPendingLockContext(
            .ssh(appName: "A", host: nil, keySummary: nil)
        )
        let second = delegate.setPendingLockContext(
            .run(appName: "B", profileName: nil, commandSummary: nil)
        )

        delegate.clearPendingLockContext(token: second)

        #expect(delegate.pendingLockContext == nil)
    }
}
