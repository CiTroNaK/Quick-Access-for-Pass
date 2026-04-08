import Testing
import Foundation
@preconcurrency import LocalAuthentication
@testable import Quick_Access_for_Pass

@Suite("Auth dialog helper")
struct AuthDialogHelperTests {
    @Test func biometryLockoutDisablesRetryAndUsesRecoveryMessage() {
        let presentation = AuthDialogHelper.failurePresentation(for: .biometryLockedOut)

        #expect(presentation.message == "Touch ID is locked. Unlock your Mac with your password to re-enable Touch ID.")
        #expect(presentation.showsRetryButton == false)
    }

    @Test func authenticationFailureStillAllowsRetry() {
        let presentation = AuthDialogHelper.failurePresentation(for: .authenticationFailed)

        #expect(presentation.message == "Authentication failed. Try again or deny.")
        #expect(presentation.showsRetryButton)
    }

    @Test func preflightLockoutDisablesRetryAndUsesRecoveryMessage() {
        let error = NSError(domain: LAError.errorDomain, code: LAError.Code.biometryLockout.rawValue)
        let presentation = AuthDialogHelper.preflightFailurePresentation(for: error)

        #expect(presentation.message == "Touch ID is locked. Unlock your Mac with your password to re-enable Touch ID.")
        #expect(presentation.showsRetryButton == false)
    }
}
