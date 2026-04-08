import Testing
import Foundation
import Security
@testable import Quick_Access_for_Pass

private let keychainTestsUnavailable: Bool = {
    let serviceName = "com.protonpass.quickaccess.probe.\(UUID().uuidString)"
    let account = "probe"
    let data = Data("probe".utf8)
    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: account,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecUseDataProtectionKeychain as String: true,
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: account,
        kSecUseDataProtectionKeychain as String: true,
    ]
    if status == errSecSuccess {
        _ = SecItemDelete(deleteQuery as CFDictionary)
        return false
    }
    return true
}()

@Suite(
    "KeychainService Tests",
    .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil || keychainTestsUnavailable,
              "Requires a signed environment with working Keychain data-protection access")
)
struct KeychainServiceTests {
    let service = KeychainService(
        serviceName: "com.protonpass.quickaccess.test.\(UUID().uuidString)"
    )

    @Test("generates and retrieves a passphrase")
    func generateAndRetrieve() throws {
        defer { try? service.deletePassphrase() }
        let passphrase = try service.getOrCreatePassphrase()
        #expect(passphrase.isEmpty == false)

        let same = try service.getOrCreatePassphrase()
        #expect(passphrase == same)
    }

    @Test("delete removes the passphrase")
    func deletePassphrase() throws {
        defer { try? service.deletePassphrase() }
        _ = try service.getOrCreatePassphrase()
        try service.deletePassphrase()

        let newPassphrase = try service.getOrCreatePassphrase()
        #expect(newPassphrase.isEmpty == false)
    }

    @Test("generated passphrase is 64 hex characters (32 bytes)")
    func passphraseLength() throws {
        defer { try? service.deletePassphrase() }
        let passphrase = try service.getOrCreatePassphrase()
        #expect(passphrase.count == 64)
        #expect(String(decoding: passphrase, as: UTF8.self).allSatisfy { $0.isHexDigit })
    }

    @Test("store handles duplicate by updating existing entry")
    func storeHandlesDuplicate() throws {
        defer { try? service.deletePassphrase() }
        // First store
        try service.store("first-passphrase")
        // Second store should hit errSecDuplicateItem and update
        try service.store("second-passphrase")
        // Retrieve should return the updated value
        let retrieved = try service.getOrCreatePassphrase()
        #expect(retrieved == Data("second-passphrase".utf8))
    }

    @Test func biometricAuthKindAppHasDedicatedAccount() {
        #expect(KeychainService.BiometricAuthKind.app != .ssh)
        #expect(KeychainService.BiometricAuthKind.app != .run)
    }
}
