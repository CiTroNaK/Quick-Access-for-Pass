import Foundation
@preconcurrency import LocalAuthentication
import Testing
@testable import Quick_Access_for_Pass

@Suite("Locked view authentication outcomes")
@MainActor
struct LockedViewAuthenticationTests {
    @Test(
        "Cancellation outcomes deny panel unlock",
        arguments: [
            LAError.Code.userCancel,
            .userFallback,
            .appCancel,
            .systemCancel,
        ]
    )
    func cancellationOutcomeDeniesPanelUnlock(errorCode: LAError.Code) async {
        let attemptID = UUID()
        var didUnlock = false
        var didCancel = false
        var endedAttemptID: UUID?
        let view = LockedView(
            onUnlockSuccess: { didUnlock = true },
            onUnlockCancelled: { didCancel = true },
            beginUnlock: { attemptID },
            endUnlock: { endedAttemptID = $0 },
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            pendingContext: nil,
            autoUnlockToken: nil,
            evaluatePolicy: { _, _, _ in
                throw LAError(errorCode)
            }
        )

        await view.unlock()

        #expect(didCancel)
        #expect(didUnlock == false)
        #expect(endedAttemptID == attemptID)
    }

    @Test("A false policy result denies panel unlock")
    func falsePolicyResultDeniesPanelUnlock() async {
        let attemptID = UUID()
        var didUnlock = false
        var didCancel = false
        var endedAttemptID: UUID?
        let view = LockedView(
            onUnlockSuccess: { didUnlock = true },
            onUnlockCancelled: { didCancel = true },
            beginUnlock: { attemptID },
            endUnlock: { endedAttemptID = $0 },
            keychainService: FakeBiometricAuthorizer(outcome: .success(())),
            pendingContext: nil,
            autoUnlockToken: nil,
            evaluatePolicy: { _, _, _ in false }
        )

        await view.unlock()

        #expect(didCancel)
        #expect(didUnlock == false)
        #expect(endedAttemptID == attemptID)
    }
}
