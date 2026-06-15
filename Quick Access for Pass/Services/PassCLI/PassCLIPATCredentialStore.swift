import Foundation
import Security

protocol PassCLIPATCredentialStoring: Sendable {
    func loadToken() async throws -> String?
    func saveToken(_ token: String) async throws
    func deleteToken() async throws
    func hasToken() async -> Bool
}

actor KeychainPassCLIPATCredentialStore: PassCLIPATCredentialStoring {
    private let serviceName: String
    private let account = "pass-cli-personal-access-token"

    init(serviceName: String = "codes.petr.quick-access-for-pass") {
        self.serviceName = serviceName
    }

    func loadToken() async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.retrieveFailed(status)
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.retrieveFailed(status)
        }
    }

    func saveToken(_ token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let data = trimmed.data(using: .utf8) else {
            throw KeychainError.storeFailed(errSecParam)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let updateStatus = SecItemUpdate(
                searchQuery as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.storeFailed(updateStatus)
            }
        default:
            throw KeychainError.storeFailed(status)
        }
    }

    func deleteToken() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func hasToken() async -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound, errSecInteractionNotAllowed:
            return false
        default:
            return false
        }
    }
}
