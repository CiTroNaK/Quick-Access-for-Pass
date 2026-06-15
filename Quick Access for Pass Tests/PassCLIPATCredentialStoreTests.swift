import Foundation
import Security
import Testing
@testable import Quick_Access_for_Pass

private let patKeychainTestsUnavailable: Bool = {
    let serviceName = "codes.petr.quick-access-for-pass.tests.pat.probe.\(UUID().uuidString)"
    let account = "pass-cli-personal-access-token"
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

@MainActor
@Suite(
    .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil || patKeychainTestsUnavailable,
              "Requires a signed environment with working Keychain data-protection access")
)
struct PassCLIPATCredentialStoreTests {
    @Test(.timeLimit(.minutes(1)))
    func saveLoadHasAndDeleteToken() async throws {
        let serviceName = "codes.petr.quick-access-for-pass.tests.pat.\(UUID().uuidString)"
        let store = KeychainPassCLIPATCredentialStore(serviceName: serviceName)

        #expect(await store.hasToken() == false)
        #expect(try await store.loadToken() == nil)

        try await store.saveToken("pst_test_token::secret")

        #expect(await store.hasToken() == true)
        #expect(try await store.loadToken() == "pst_test_token::secret")

        try await store.deleteToken()

        #expect(await store.hasToken() == false)
        #expect(try await store.loadToken() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func saveTokenUpdatesExistingToken() async throws {
        let serviceName = "codes.petr.quick-access-for-pass.tests.pat.\(UUID().uuidString)"
        let store = KeychainPassCLIPATCredentialStore(serviceName: serviceName)

        try await store.saveToken("first-token")
        try await store.saveToken("second-token")

        #expect(try await store.loadToken() == "second-token")

        try await store.deleteToken()
    }
}
