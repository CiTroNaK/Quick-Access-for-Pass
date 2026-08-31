import SwiftUI
@preconcurrency import LocalAuthentication

struct LockedView: View {
    typealias PolicyEvaluator = (LAContext, LAPolicy, String) async throws -> Bool

    let onUnlockSuccess: () -> Void
    let onUnlockCancelled: () -> Void
    let beginUnlock: () -> UUID?
    let endUnlock: (UUID) -> Void
    let keychainService: any BiometricAuthorizing
    let pendingContext: PendingLockContext?
    let autoUnlockToken: UUID?
    private let evaluatePolicy: PolicyEvaluator

    @State private var errorMessage: String?
    @State private var isBiometryLockedOut = false
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 48

    init(
        onUnlockSuccess: @escaping () -> Void,
        onUnlockCancelled: @escaping () -> Void,
        beginUnlock: @escaping () -> UUID?,
        endUnlock: @escaping (UUID) -> Void,
        keychainService: any BiometricAuthorizing,
        pendingContext: PendingLockContext?,
        autoUnlockToken: UUID?,
        evaluatePolicy: @escaping PolicyEvaluator = { context, policy, reason in
            try await context.evaluatePolicy(policy, localizedReason: reason)
        }
    ) {
        self.onUnlockSuccess = onUnlockSuccess
        self.onUnlockCancelled = onUnlockCancelled
        self.beginUnlock = beginUnlock
        self.endUnlock = endUnlock
        self.keychainService = keychainService
        self.pendingContext = pendingContext
        self.autoUnlockToken = autoUnlockToken
        self.evaluatePolicy = evaluatePolicy
    }

    private static func composedLabel(for context: PendingLockContext) -> String {
        if let detail = context.detailLine {
            return "\(context.primaryLine). \(detail)"
        }
        return context.primaryLine
    }

    static func makeAuthenticationContext() -> LAContext {
        let context = LAContext()
        // Allow the keychain call to reuse this authentication within
        // a short window. Must be set BEFORE evaluatePolicy. Matches
        // AuthDialogHelper.runAuthorize so both hybrid-pattern paths
        // have the same reuse semantics.
        context.touchIDAuthenticationAllowableReuseDuration = 10
        // Password fallback is only offered after biometry lockout through
        // the view's explicit retry path. Hiding the system fallback avoids
        // LAError.userFallback leaving proxy waiters pending until timeout.
        context.localizedFallbackTitle = ""
        return context
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Quick Access is Locked")
                .font(.title2)
                .fontWeight(.medium)
            if let pendingContext {
                VStack(spacing: 4) {
                    Text(pendingContext.primaryLine)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                    if let detailLine = pendingContext.detailLine {
                        Text(detailLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 260)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.composedLabel(for: pendingContext))
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button(
                isBiometryLockedOut
                    ? String(localized: "Unlock with Password")
                    : String(localized: "Unlock with Touch ID")
            ) {
                Task { await unlock() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: pendingContext, initial: true) { _, newValue in
            if let newValue {
                AccessibilityNotification.Announcement(
                    Self.composedLabel(for: newValue)
                ).post()
            }
        }
        .task(id: autoUnlockToken) {
            guard autoUnlockToken != nil, !isBiometryLockedOut else { return }
            await unlock()
        }
    }

    /// Runs one panel authentication attempt.
    /// Internal so authentication outcomes can be verified without presenting the SwiftUI view.
    func unlock() async {
        guard let attemptID = beginUnlock() else { return }
        defer { endUnlock(attemptID) }
        let context = Self.makeAuthenticationContext()
        let policy: LAPolicy = isBiometryLockedOut
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics

        do {
            let didAuthenticate = try await evaluatePolicy(
                context,
                policy,
                String(localized: "Unlock Quick Access")
            )
            guard didAuthenticate else {
                onUnlockCancelled()
                return
            }
        } catch let laError as LAError {
            switch laError.code {
            case .biometryLockout:
                isBiometryLockedOut = true
                errorMessage = String(localized: "Touch ID is locked. Use your password instead.")
                return
            case .userCancel, .userFallback, .appCancel, .systemCancel:
                onUnlockCancelled()
                return
            default:
                errorMessage = laError.localizedDescription
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // Security note — password fallback path (`isBiometryLockedOut == true`).
        //
        // The biometry path below runs the hybrid pattern (evaluatePolicy +
        // keychain-bound read). The password fallback is intentionally
        // keychain-unbound because the `.app` sentinel's ACL requires
        // biometry (`.biometryCurrentSet`) — a password-only LAContext cannot
        // satisfy the keychain read.
        //
        // Defense-in-depth is preserved because every secret-touching path
        // (SSHAgentProxy, RunProxy) independently enforces the same
        // biometry-only hybrid pattern on each request. Fake-unlocking this
        // panel only gets an attacker to the search UI, not to any secret.
        //
        // Future maintainers: do NOT remove the keychain step from SSH/Run
        // to "match" this view.
        if !isBiometryLockedOut {
            context.interactionNotAllowed = true
            do {
                try await keychainService.authorize(kind: .app, context: context)
            } catch {
                errorMessage = String(localized: "Authentication failed. Try again.")
                return
            }
        }

        errorMessage = nil
        onUnlockSuccess()
    }
}
