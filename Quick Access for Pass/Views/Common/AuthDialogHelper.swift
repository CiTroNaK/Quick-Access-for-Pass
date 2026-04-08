import Foundation
@preconcurrency import LocalAuthentication

/// Extracted authentication logic for SSH and Run auth dialogs.
///
/// ## Why this helper exists
///
/// The dialogs previously called `LAContext.evaluatePolicy` directly and
/// treated its `Bool` return value as the sole authorization signal —
/// the textbook anti-pattern from `common-anti-patterns.md` #3. A
/// one-line Frida hook on `-[LAContext evaluatePolicy:localizedReason:reply:]`
/// bypassed the whole gate.
///
/// ## The hybrid pattern (C1 fix)
///
/// This helper implements a two-step flow that keeps the embedded
/// `LAAuthenticationView` UI AND closes the bypass:
///
/// 1. `LAContext.evaluatePolicy` runs the familiar embedded biometric
///    UI. The `LAAuthenticationView` already bound to this context by
///    the dialog's view body animates the fingerprint icon in place.
///    A successful `evaluatePolicy` call causes `coreauthd` (the system
///    authentication daemon) to record the context as authenticated.
///    That recorded state lives in coreauthd's address space, not in
///    user-space Swift.
///
/// 2. `SecItemCopyMatching` retrieves a biometric-protected sentinel
///    via `kSecUseAuthenticationContext`. Before the keychain query,
///    we set `context.interactionNotAllowed = true` so the keychain
///    MUST satisfy the query from the reused authentication — it is
///    not allowed to show any additional UI. If the context is really
///    authenticated, the keychain retrieves the sentinel silently.
///    If the context is NOT actually authenticated (e.g., a Frida hook
///    forced `evaluatePolicy`'s reply block to `success = true` without
///    updating coreauthd's state), the keychain returns
///    `errSecInteractionNotAllowed` — which we map to a denial.
///
/// ## Why this raises the bar against the original attack
///
/// The original C1 vulnerability was: hook `evaluatePolicy`, force the
/// reply block to `success = true`, bypass the gate with one line.
/// Under the hybrid pattern, that same hook leaves coreauthd's state
/// uninitialized for the context, because the hook never actually
/// invoked the real method → real IPC → coreauthd update. The keychain
/// call in step 2 checks coreauthd via XPC (not user-space state), finds
/// no valid auth, and fails — because we set `interactionNotAllowed`,
/// it can't fall back to showing its own prompt either.
///
/// The remaining attack requires either: (a) running as root with
/// privileges to forge coreauthd state, (b) a kernel-level compromise,
/// or (c) an attack that lets `evaluatePolicy` actually reach the
/// Secure Enclave under the attacker's control — which means the real
/// Touch ID prompt appears, which the user would notice. All three are
/// significantly higher-bar attacks than a one-line Frida script.
///
/// ## Touch ID reuse duration
///
/// `LAContext.touchIDAuthenticationAllowableReuseDuration` must be set
/// BEFORE `evaluatePolicy` for the reuse to work. Default is 0 (no
/// reuse). This helper sets it to 10 s, which is well within the
/// auth-to-keychain round-trip time but short enough that the context
/// cannot be stashed for later abuse.
enum AuthDialogHelper {
    /// Lifecycle callbacks injected by the caller. Kept per-call rather
    /// than on a shared static so the helper holds no process-global
    /// mutable state.
    ///
    /// `onAuthSuccess` fires after the keychain-bound step succeeds.
    /// `onBiometryLockout` fires when LocalAuthentication reports
    /// `.biometryLockout` mid-auth. Both are sync for symmetry; the
    /// production targets (`resetAuthTimestamp()`, `forceLock()`) are
    /// sync MainActor methods.
    nonisolated struct Callbacks: Sendable {
        let onAuthSuccess: @MainActor @Sendable () -> Void
        let onBiometryLockout: @MainActor @Sendable () -> Void

        /// Convenience for tests that don't need to observe the callbacks.
        static let noop = Callbacks(onAuthSuccess: { }, onBiometryLockout: { })
    }

    nonisolated enum Outcome: Equatable {
        case allowed
        case denied(BiometricAuthError)
    }

    nonisolated struct FailurePresentation: Equatable {
        let message: String
        let showsRetryButton: Bool
    }

    /// Pre-authenticates the context via `LAContext.evaluatePolicy`
    /// (which drives the embedded `LAAuthenticationView` UI), then
    /// passes the pre-authenticated context to the authorizer's
    /// keychain-bound retrieval. The keychain call is forbidden from
    /// showing additional UI — if the pre-authentication was not real
    /// (hook bypass), the keychain returns an error and the helper
    /// denies.
    ///
    /// - Parameters:
    ///   - context: The `LAContext` bound to the dialog's embedded
    ///     `LAAuthenticationView`. Must be the same instance that the
    ///     dialog's view body has rendered, so the embedded UI animates
    ///     correctly during `evaluatePolicy`.
    ///   - authorizer: The keychain-bound authorizer. Production uses
    ///     `KeychainService`; tests use `FakeBiometricAuthorizer` /
    ///     `SpyBiometricAuthorizer`.
    ///   - kind: Which sentinel to retrieve (.ssh or .run).
    ///   - localizedReason: The message shown to the user in the Touch
    ///     ID prompt. Set on the context immediately before the
    ///     `evaluatePolicy` call.
    ///
    /// Marked `nonisolated static` to document that the helper carries
    /// no actor isolation assumption.
    nonisolated static func runAuthorize(
        context: LAContext,
        authorizer: any BiometricAuthorizing,
        kind: KeychainService.BiometricAuthKind,
        localizedReason: String,
        callbacks: Callbacks
    ) async -> Outcome {
        // Allow the keychain call to reuse this authentication within
        // a short window. Must be set BEFORE evaluatePolicy.
        context.touchIDAuthenticationAllowableReuseDuration = 10

        // Step 1 — drive the embedded LAAuthenticationView via
        // evaluatePolicy. On success, coreauthd records the context as
        // authenticated in its own address space.
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: localizedReason
            )
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .denied(.userCancelled)
            case .biometryLockout:
                await callbacks.onBiometryLockout()
                return .denied(.biometryLockedOut)
            case .biometryNotAvailable, .biometryNotEnrolled:
                return .denied(.biometryUnavailable(laError.localizedDescription))
            case .authenticationFailed:
                return .denied(.authenticationFailed)
            default:
                return .denied(.authenticationFailed)
            }
        } catch {
            return .denied(.authenticationFailed)
        }

        // Step 2 — block any further UI. The keychain call MUST satisfy
        // the query from reused authentication or fail outright. A
        // hook-forged `evaluatePolicy` success leaves coreauthd's state
        // uninitialized for this context, and without the ability to
        // prompt, the keychain has no way to proceed.
        context.interactionNotAllowed = true

        do {
            try await authorizer.authorize(kind: kind, context: context)
            await callbacks.onAuthSuccess()
            return .allowed
        } catch let error as BiometricAuthError {
            return .denied(error)
        } catch {
            return .denied(.authenticationFailed)
        }
    }

    nonisolated static func failurePresentation(for error: BiometricAuthError) -> FailurePresentation {
        switch error {
        case .biometryLockedOut:
            return FailurePresentation(
                message: String(localized: "Touch ID is locked. Unlock your Mac with your password to re-enable Touch ID."),
                showsRetryButton: false
            )
        case .userCancelled:
            return FailurePresentation(
                message: String(localized: "Authentication cancelled. Try again or deny."),
                showsRetryButton: true
            )
        case .authenticationFailed:
            return FailurePresentation(
                message: String(localized: "Authentication failed. Try again or deny."),
                showsRetryButton: true
            )
        case .interactionNotAllowed:
            return FailurePresentation(
                message: String(localized: "Device is locked. Unlock and try again."),
                showsRetryButton: true
            )
        case .biometryUnavailable(let message):
            return FailurePresentation(
                message: String(localized: "Touch ID not available: \(message)"),
                showsRetryButton: true
            )
        case .keychainFailure:
            return FailurePresentation(
                message: String(localized: "Authentication failed. Try again or deny."),
                showsRetryButton: true
            )
        }
    }

    nonisolated static func preflightFailurePresentation(for error: NSError?) -> FailurePresentation {
        if let error,
           error.domain == LAError.errorDomain,
           LAError.Code(rawValue: error.code) == .biometryLockout {
            return failurePresentation(for: .biometryLockedOut)
        }

        return FailurePresentation(
            message: String(localized: "Touch ID not available: \(error?.localizedDescription ?? "unknown error")"),
            showsRetryButton: true
        )
    }
}
