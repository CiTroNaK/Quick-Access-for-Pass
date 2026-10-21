import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill app association store")
struct AutoFillAppAssociationStoreTests {
    private let passphrase = Data("app-association-test".utf8)

    @Test("replaces an exact app association and retains its display label for presentation")
    func replacesExactAppAssociation() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        let descriptors = try seedDescriptors(database)
        let service = try AutoFillServiceIdentifier(kind: .app, identifier: "com.example.app", displayName: "Example App")
        let store = AutoFillAppAssociationStore(databaseManager: database)

        try await store.save(service: service, descriptorID: descriptors.first.id, createdAt: Date(timeIntervalSince1970: 1))
        try await store.save(service: service, descriptorID: descriptors.second.id, createdAt: Date(timeIntervalSince1970: 2))

        let associations = try await store.associations()
        #expect(associations.count == 1)
        #expect(associations.first?.serviceIdentifier == "com.example.app")
        #expect(associations.first?.serviceDisplayName == "Example App")
        #expect(associations.first?.descriptorID == descriptors.second.id)
    }

    @Test("deletes associations explicitly and when their descriptor is deleted")
    func deletesExplicitlyAndCascades() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        let descriptors = try seedDescriptors(database)
        let first = try AutoFillServiceIdentifier(kind: .app, identifier: "com.example.first", displayName: nil)
        let second = try AutoFillServiceIdentifier(kind: .app, identifier: "com.example.second", displayName: nil)
        let store = AutoFillAppAssociationStore(databaseManager: database)
        try await store.save(service: first, descriptorID: descriptors.first.id, createdAt: .now)
        try await store.save(service: second, descriptorID: descriptors.second.id, createdAt: .now)

        try await store.delete(service: first)
        #expect(try await store.associations().map(\.serviceIdentifier) == ["com.example.second"])

        try await database.writer.write { db in
            try AutoFillCredentialDescriptor.deleteOne(db, key: descriptors.second.id)
        }
        #expect(try await store.associations().isEmpty)
    }

    @Test("rejects non-app associations without using Keychain")
    func rejectsNonAppAssociation() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: passphrase)
        let descriptors = try seedDescriptors(database)
        let service = try AutoFillServiceIdentifier(kind: .domain, identifier: "example.com", displayName: nil)
        let store = AutoFillAppAssociationStore(databaseManager: database)

        await #expect(throws: AutoFillAppAssociationStore.Error.invalidService) {
            try await store.save(service: service, descriptorID: descriptors.first.id, createdAt: .now)
        }
        #expect(try await store.associations().isEmpty)
    }

    private func seedDescriptors(_ database: DatabaseManager) throws -> (first: AutoFillCredentialDescriptor, second: AutoFillCredentialDescriptor) {
        let descriptors = try database.syncMetadata(
            vaults: [PassVault(id: "vault", name: "Personal", shareId: "share")],
            items: [
                makeItem(id: "one", username: "one@example.com"),
                makeItem(id: "two", username: "two@example.com")
            ],
            descriptors: [
                AutoFillDescriptorInput(vaultID: "vault", itemID: "one", shareID: "share", title: "One", username: "one@example.com", serviceIdentifier: "example.com", hasTOTP: false),
                AutoFillDescriptorInput(vaultID: "vault", itemID: "two", shareID: "share", title: "Two", username: "two@example.com", serviceIdentifier: "example.com", hasTOTP: false)
            ]
        )
        return (descriptors[0], descriptors[1])
    }

    private func makeItem(id: String, username: String) -> PassItem {
        PassItem(
            id: id,
            vaultId: "vault",
            title: id,
            itemType: .login,
            subtitle: username,
            url: "https://example.com",
            hasTOTP: false,
            state: "Active",
            createTime: .now,
            modifyTime: .now,
            useCount: 0,
            lastUsedAt: nil
        )
    }
}
