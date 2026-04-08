import Foundation
@preconcurrency import LocalAuthentication
@testable import Quick_Access_for_Pass

/// Test fake that records calls and returns a configured outcome.
/// The `LAContext` argument is captured but not acted on.
///
/// `@preconcurrency import LocalAuthentication` is required because
/// `LAContext` is not `Sendable` in the standard library and this
/// file conforms to `BiometricAuthorizing`, which has a non-Sendable
/// parameter.
nonisolated struct FakeBiometricAuthorizer: BiometricAuthorizing, Sendable {
    let outcome: Result<Void, BiometricAuthError>

    init(outcome: Result<Void, BiometricAuthError>) {
        self.outcome = outcome
    }

    func authorize(
        kind: KeychainService.BiometricAuthKind,
        context: LAContext
    ) async throws {
        try outcome.get()
    }
}

/// Spy variant of `FakeBiometricAuthorizer` that captures
/// `context.localizedReason` at the moment `authorize(kind:context:)`
/// is called. Used by the `localizedReasonIsSetOnContext` test to
/// verify that the helper sets the reason BEFORE invoking the
/// authorizer, not just eventually.
final class SpyCapture: @unchecked Sendable {
    var seenLocalizedReason: String?
}

nonisolated struct SpyBiometricAuthorizer: BiometricAuthorizing, Sendable {
    let outcome: Result<Void, BiometricAuthError>
    let capture: SpyCapture

    func authorize(
        kind: KeychainService.BiometricAuthKind,
        context: LAContext
    ) async throws {
        capture.seenLocalizedReason = context.localizedReason
        try outcome.get()
    }
}
