import Foundation
import Security
@preconcurrency import LocalAuthentication

nonisolated struct KeychainService: Sendable {
    let serviceName: String
    private let databasePassphraseAccount = "database-passphrase"

    init(serviceName: String = "codes.petr.quick-access-for-pass") {
        self.serviceName = serviceName
    }

    func getOrCreatePassphrase() throws -> Data {
        if let existing = try retrieve() {
            return Data(existing.utf8)
        }
        let passphrase = try generatePassphrase()
        try store(passphrase)
        return Data(passphrase.utf8)
    }

    func deletePassphrase() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: databasePassphraseAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private func retrieve() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: databasePassphraseAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.retrieveFailed(status)
        }
        return string
    }

    func store(_ passphrase: String) throws {
        guard let data = passphrase.data(using: .utf8) else {
            throw KeychainError.storeFailed(errSecParam)
        }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: databasePassphraseAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: databasePassphraseAccount,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let updateStatus = SecItemUpdate(
                searchQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.storeFailed(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.storeFailed(status)
        }
    }

    private func generatePassphrase() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.randomGenerationFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum KeychainError: Error, LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        // OSStatus results
        // swiftlint:disable identifier_name
        switch self {
        case .storeFailed(let s): String(localized: "Keychain store failed: \(s)")
        case .retrieveFailed(let s): String(localized: "Keychain retrieve failed: \(s)")
        case .deleteFailed(let s): String(localized: "Keychain delete failed: \(s)")
        case .randomGenerationFailed(let s): String(localized: "Secure random generation failed: \(s)")
        }
        // swiftlint:enable identifier_name
    }
}

// MARK: - Biometric Authorization

/// Kind of biometric-gated action being authorized.
///
/// Each kind corresponds to a distinct `GenericPassword` keychain
/// sentinel item under the same service. Retrieving a sentinel via
/// `SecItemCopyMatching` against its `SecAccessControl(.biometryCurrentSet)`
/// wrapper is the authorization signal; the retrieved bytes are discarded.
extension KeychainService {
    nonisolated enum BiometricAuthKind: Sendable, Equatable {
        case ssh
        case run
        case app

        fileprivate var account: String {
            switch self {
            case .ssh: return "ssh-auth-sentinel"
            case .run: return "run-auth-sentinel"
            case .app: return "app-unlock-sentinel"
            }
        }
    }
}

/// Abstraction over biometric authorization. Conformed to by
/// `KeychainService` in production and by `FakeBiometricAuthorizer`
/// in tests, so dialog state-machine logic can be exercised without
/// touching real Touch ID hardware.
///
/// Note on `LAContext` and Sendable: `LAContext` is a reference type
/// that Apple has not annotated `Sendable`. Every file that imports
/// this protocol and constructs or calls with an `LAContext` must use
/// `@preconcurrency import LocalAuthentication` to suppress the
/// checker. Apple's documentation explicitly supports passing an
/// `LAContext` across threads for the purpose of a single keychain or
/// `evaluatePolicy` call — we are not touching its mutable state from
/// multiple threads concurrently.
protocol BiometricAuthorizing: Sendable {
    func authorize(
        kind: KeychainService.BiometricAuthKind,
        context: LAContext
    ) async throws
}

/// Error surfaced from `BiometricAuthorizing.authorize(kind:context:)`.
/// Maps directly to the dialog's failure states.
nonisolated enum BiometricAuthError: Error, LocalizedError, Equatable {
    case biometryUnavailable(String)
    case biometryLockedOut
    case userCancelled
    case authenticationFailed
    case interactionNotAllowed
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .biometryUnavailable(let message):
            return String(localized: "Touch ID not available: \(message)")
        case .biometryLockedOut:
            return String(localized: "Touch ID is locked. Unlock your Mac with your password to re-enable Touch ID.")
        case .userCancelled:
            return String(localized: "Authentication cancelled.")
        case .authenticationFailed:
            return String(localized: "Authentication failed.")
        case .interactionNotAllowed:
            return String(localized: "Device is locked. Unlock and try again.")
        case .keychainFailure(let status):
            return String(localized: "Keychain error: \(status)")
        }
    }
}

// MARK: - BiometricAuthorizing conformance

extension KeychainService: BiometricAuthorizing {

    /// Authorize a biometric-gated action by retrieving a sentinel keychain
    /// item protected by `.biometryCurrentSet`. Returns on success; throws
    /// `BiometricAuthError` on any failure. The retrieved data is discarded —
    /// the act of retrieval is the authorization signal.
    ///
    /// Biometric authorization flow (hybrid pattern):
    ///
    /// 1. The dialog embeds `LAAuthenticationView`, which presents the system
    ///    biometric UI and calls `evaluatePolicy` on the shared `LAContext`.
    /// 2. That same `LAContext` is then passed here, with reuse semantics handled
    ///    by LocalAuthentication.
    /// 3. `blockingAuthorize` calls `SecItemCopyMatching` with
    ///    `kSecUseAuthenticationContext`, binding the authorization to a real
    ///    keychain sentinel item.
    ///
    /// This gives us the embedded `LAAuthenticationView` UX without losing the
    /// keychain-bound security of an actual `.biometryCurrentSet` item lookup.
    ///
    /// If the sentinel does not exist (first use, or biometric enrollment
    /// change invalidated it), it is created lazily and the retrieval is
    /// retried exactly once.
    ///
    /// - Parameters:
    ///   - kind: Which sentinel to retrieve (.ssh or .run).
    ///   - context: The `LAContext` to use for the biometric prompt. Pass
    ///     the dialog's own `@State` context so the embedded
    ///     `LAAuthenticationView` reflects the auth state.
    func authorize(kind: BiometricAuthKind, context: LAContext) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let outcome = Self.blockingAuthorize(
                    serviceName: self.serviceName,
                    account: kind.account,
                    context: context
                )
                cont.resume(with: outcome)
            }
        }
    }

    private nonisolated static func blockingAuthorize(
        serviceName: String,
        account: String,
        context: LAContext
    ) -> Result<Void, Error> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return .success(())
        case errSecItemNotFound:
            return createSentinelAndRetry(
                serviceName: serviceName,
                account: account,
                context: context
            )
        case errSecUserCanceled:
            return .failure(BiometricAuthError.userCancelled)
        case errSecAuthFailed:
            return .failure(BiometricAuthError.authenticationFailed)
        case errSecInteractionNotAllowed:
            return .failure(BiometricAuthError.interactionNotAllowed)
        case errSecNotAvailable:
            // Intel Mac without Touch ID, or biometric hardware present
            // but unreachable at this moment. The dialog's preflight
            // `canEvaluatePolicy` check should usually catch this first,
            // but it can still reach here if the policy evaluated as
            // available via a password fallback while the keychain
            // operation specifically needs biometry.
            return .failure(BiometricAuthError.biometryUnavailable("Touch ID not available on this device"))
        default:
            return .failure(BiometricAuthError.keychainFailure(status))
        }
    }

    private nonisolated static func createSentinelAndRetry(
        serviceName: String,
        account: String,
        context: LAContext
    ) -> Result<Void, Error> {
        // Recovery path: the sentinel is either missing (first use on
        // this install) or cryptographically invalidated by a Touch ID
        // enrollment change. In both cases we delete-then-add rather
        // than using the usual add-or-update pattern — updating a
        // `.biometryCurrentSet`-wrapped item does NOT regenerate the
        // Secure Enclave key wrapping; only a fresh `SecItemAdd` does.
        // This is a deliberate, narrow exception to Core Guideline #6.
        //
        // Best-effort delete tolerates both "doesn't exist" and
        // "exists but stale".
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)

        // 32 random bytes — the value itself is irrelevant.
        var bytes = [UInt8](repeating: 0, count: 32)
        let randStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randStatus == errSecSuccess else {
            return .failure(BiometricAuthError.keychainFailure(randStatus))
        }

        var cfError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &cfError
        ) else {
            _ = cfError?.takeRetainedValue()
            return .failure(BiometricAuthError.keychainFailure(errSecParam))
        }

        // No kSecAttrAccessible here — it is encoded inside the access control.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(bytes),
            kSecAttrAccessControl as String: accessControl,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return .failure(BiometricAuthError.keychainFailure(addStatus))
        }

        // Exactly one retry. No loop.
        let retryQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var retryResult: AnyObject?
        let retryStatus = SecItemCopyMatching(retryQuery as CFDictionary, &retryResult)
        switch retryStatus {
        case errSecSuccess:              return .success(())
        case errSecUserCanceled:         return .failure(BiometricAuthError.userCancelled)
        case errSecAuthFailed:           return .failure(BiometricAuthError.authenticationFailed)
        case errSecInteractionNotAllowed: return .failure(BiometricAuthError.interactionNotAllowed)
        case errSecNotAvailable:         return .failure(BiometricAuthError.biometryUnavailable("Touch ID not available on this device"))
        default:                         return .failure(BiometricAuthError.keychainFailure(retryStatus))
        }
    }
}
