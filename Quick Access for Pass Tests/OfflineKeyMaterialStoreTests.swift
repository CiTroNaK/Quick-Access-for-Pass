import Foundation
import Security
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline snapshot key store")
struct OfflineKeyMaterialStoreTests {
    @Test func createsOne32ByteSnapshotKeyAndReusesIt() async throws {
        let fake = SnapshotFakeKeychain()
        let store = OfflineKeyMaterialStore(serviceName: "test", backend: fake.backend)
        let first = try await store.createSnapshotKey()
        let second = try await store.createSnapshotKey()
        #expect(first.count == 32)
        #expect(first == second)
        #expect(fake.accounts == ["offline-snapshot-key"])
    }

    @Test func duplicateCreationReturnsExistingWinnerWithoutMutation() async throws {
        let winner = Data(repeating: 9, count: 32)
        let fake = SnapshotFakeKeychain(duplicateWinner: winner)
        let store = OfflineKeyMaterialStore(serviceName: "test", backend: fake.backend)
        #expect(try await store.createSnapshotKey() == winner)
        #expect(fake.adds == ["offline-snapshot-key"])
    }

    @Test func queriesUseHostOnlyDataProtectionKeychainPolicy() async throws {
        let fake = SnapshotFakeKeychain()
        let store = OfflineKeyMaterialStore(serviceName: "test", backend: fake.backend)
        _ = try await store.createSnapshotKey()
        for query in fake.queries {
            let dictionary = query.keychainDictionary
            #expect(dictionary[kSecAttrAccessGroup as String] as? String == AutoFillConstants.keychainAccessGroup)
            #expect(dictionary[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(dictionary[kSecUseDataProtectionKeychain as String] as? Bool == true)
            if query.kind == .add {
                #expect(dictionary[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            }
        }
    }

    @Test func missingOrInvalidKeysAreTypedAndDoNotCreateOnRead() async throws {
        let fake = SnapshotFakeKeychain(initial: ["offline-snapshot-key": Data(repeating: 1, count: 31)])
        let store = OfflineKeyMaterialStore(serviceName: "test", backend: fake.backend)
        await #expect(throws: OfflineKeyMaterialStore.Error.invalidMaterial) { _ = try await store.existingSnapshotKey() }
        #expect(fake.adds.isEmpty)
    }

    @Test func interactionLockedRetrievalDoesNotAddOrMutateKeyMaterial() async {
        let fake = SnapshotFakeKeychain(retrieveStatus: errSecInteractionNotAllowed)
        let store = OfflineKeyMaterialStore(serviceName: "test", backend: fake.backend)

        await #expect(throws: OfflineKeyMaterialStore.Error.interactionNotAllowed) {
            _ = try await store.createSnapshotKey()
        }
        #expect(fake.adds.isEmpty)
        #expect(fake.accounts.isEmpty)
    }

    @Test func unexpectedRetrievalStatusIsTypedWithoutAddingKeyMaterial() async {
        let fake = SnapshotFakeKeychain(retrieveStatus: errSecAuthFailed)
        let store = OfflineKeyMaterialStore(serviceName: "test", backend: fake.backend)

        await #expect(throws: OfflineKeyMaterialStore.Error.securityStatus(errSecAuthFailed)) {
            _ = try await store.existingSnapshotKey()
        }
        #expect(fake.adds.isEmpty)
        #expect(fake.accounts.isEmpty)
    }
}

private final class SnapshotFakeKeychain: Sendable {
    private struct State { var values: [String: Data]; var queries: [OfflineKeyMaterialStore.Query] = []; var adds: [String] = [] }
    private let state: Mutex<State>
    private let duplicateWinner: Data?
    private let retrieveStatus: OSStatus?

    init(
        duplicateWinner: Data? = nil,
        retrieveStatus: OSStatus? = nil,
        initial: [String: Data] = [:]
    ) {
        self.duplicateWinner = duplicateWinner
        self.retrieveStatus = retrieveStatus
        state = Mutex(.init(values: initial))
    }
    var backend: OfflineKeyMaterialStore.Backend {
        .init(
            retrieve: { [self] query in
                state.withLock { state in
                    state.queries.append(query)
                    if let retrieveStatus { return .failure(retrieveStatus) }
                    guard let value = state.values[query.account] else { return .failure(errSecItemNotFound) }
                    return .success(value)
                }
            },
            add: { [self] query in
                state.withLock { state in
                    state.queries.append(query); state.adds.append(query.account)
                    if let duplicateWinner { state.values[query.account] = duplicateWinner; return errSecDuplicateItem }
                    state.values[query.account] = query.data!; return errSecSuccess
                }
            }
        )
    }
    var accounts: [String] { state.withLock { $0.values.keys.sorted() } }
    var queries: [OfflineKeyMaterialStore.Query] { state.withLock { $0.queries } }
    var adds: [String] { state.withLock { $0.adds } }
}
