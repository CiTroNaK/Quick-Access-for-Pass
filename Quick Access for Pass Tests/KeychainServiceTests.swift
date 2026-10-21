import Testing
import Foundation
import Security
import Synchronization
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
        try service.store("first-passphrase")
        try service.store("second-passphrase")
        let retrieved = try service.getOrCreatePassphrase()
        #expect(retrieved == Data("second-passphrase".utf8))
    }

    @Test func biometricAuthKindAppHasDedicatedAccount() {
        #expect(KeychainService.BiometricAuthKind.app != .ssh)
        #expect(KeychainService.BiometricAuthKind.app != .run)
    }
}

@Suite("Keychain passphrase policy")
struct KeychainPassphrasePolicyTests {
    @Test("all passphrase query kinds target the unchanged shared group and data-protection keychain")
    func exactSharedQueryPolicy() {
        for kind in KeychainPassphraseQueryKind.allCases {
            let query = KeychainService.PassphraseQuery(
                kind: kind,
                serviceName: "codes.petr.quick-access-for-pass",
                accessGroup: AutoFillConstants.keychainAccessGroup,
                value: kind == .add || kind == .update ? Data("value".utf8) : nil
            )
            let dictionary = query.searchDictionary
            #expect(dictionary[kSecAttrAccessGroup as String] as? String == "H23TXL6LPT.codes.petr.quick-access-for-pass")
            #expect(dictionary[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(dictionary[kSecClass as String] as? String == kSecClassGenericPassword as String)
            if kind == .add {
                #expect(dictionary[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            }
        }
    }

    @Test("explicit shared-group hit returns the unchanged passphrase without a write")
    func explicitHitDoesNotWrite() throws {
        let calls = CallRecorder()
        let expected = Data("unchanged".utf8)
        let service = makeService(calls: calls, lookup: .success(expected))

        let actual = try service.retrievePassphrase()

        #expect(actual == expected)
        #expect(calls.values == [.retrieve])
    }

    @Test("lookup errors and locked-device errors never create a replacement")
    func lookupErrorsNeverCreate() {
        for error in [KeychainError.retrieveFailed(errSecInteractionNotAllowed), .retrieveFailed(errSecAuthFailed)] {
            let calls = CallRecorder()
            let service = makeService(calls: calls, lookup: .failure(error))

            #expect(throws: KeychainError.self) {
                _ = try service.getOrCreatePassphrase()
            }
            #expect(calls.values == [.retrieve])
        }
    }

    @Test("missing passphrase may be created only when requested explicitly")
    func getOrCreateMayGenerate() throws {
        let calls = CallRecorder()
        let service = makeService(calls: calls, lookup: .success(nil))

        let generated = try service.getOrCreatePassphrase()

        #expect(generated.count == 64)
        #expect(calls.values == [.retrieve, .add])
    }

    @Test("get-or-create returns a concurrent duplicate winner without updating it")
    func getOrCreateDuplicateReturnsWinnerWithoutUpdate() throws {
        let calls = CallRecorder()
        let winner = Data("concurrent-winner".utf8)
        let service = KeychainService(
            serviceName: "codes.petr.quick-access-for-pass",
            accessGroup: AutoFillConstants.keychainAccessGroup,
            backend: .init(
                retrieve: { query in
                    calls.append(query.kind)
                    return calls.values == [.retrieve] ? .success(nil) : .success(winner)
                },
                add: { query in
                    calls.append(query.kind)
                    return .failure(.storeFailed(errSecDuplicateItem))
                },
                update: { query in
                    calls.append(query.kind)
                    return .success(())
                },
                delete: { query in
                    calls.append(query.kind)
                    return .success(())
                }
            )
        )

        #expect(try service.getOrCreatePassphrase() == winner)
        #expect(calls.values == [.retrieve, .add, .retrieve])
    }

    private func makeService(
        calls: CallRecorder,
        lookup: Result<Data?, KeychainError>
    ) -> KeychainService {
        KeychainService(
            serviceName: "codes.petr.quick-access-for-pass",
            accessGroup: AutoFillConstants.keychainAccessGroup,
            backend: .init(
                retrieve: { query in
                    calls.append(query.kind)
                    return lookup
                },
                add: { query in
                    calls.append(query.kind)
                    return .success(())
                },
                update: { query in
                    calls.append(query.kind)
                    return .success(())
                },
                delete: { query in
                    calls.append(query.kind)
                    return .success(())
                }
            )
        )
    }
}

private final class CallRecorder: Sendable {
    private let storage = Mutex<[KeychainPassphraseQueryKind]>([])

    var values: [KeychainPassphraseQueryKind] {
        storage.withLock { $0 }
    }

    func append(_ kind: KeychainPassphraseQueryKind) {
        storage.withLock { $0.append(kind) }
    }
}
