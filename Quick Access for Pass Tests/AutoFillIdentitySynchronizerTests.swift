import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill identity synchronization")
struct AutoFillIdentitySynchronizerTests {
    @Test("registers separate password and one-time-code identities")
    func registersSeparateIdentityTypes() async throws {
        let adapter = FakeCredentialIdentityStoreAdapter()
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)
        let totpDescriptor = makeDescriptor(id: UUID(), service: "first.example", hasTOTP: true)
        let passwordOnly = makeDescriptor(id: UUID(), service: "second.example", hasTOTP: false)

        try await synchronizer.reconcile(descriptors: [totpDescriptor, passwordOnly])

        let operations = await adapter.operations()
        #expect(operations.savedPasswords == [
            AutoFillPasswordIdentity(descriptor: totpDescriptor),
            AutoFillPasswordIdentity(descriptor: passwordOnly)
        ])
        #expect(operations.savedOneTimeCodes == [AutoFillOneTimeCodeIdentity(descriptor: totpDescriptor)])
        #expect(operations.removedPasswords.isEmpty)
        #expect(operations.removedOneTimeCodes.isEmpty)
    }

    @Test("removes stale one-time-code identity without dropping password identity")
    func totpBecomingUnavailable() async throws {
        let id = UUID()
        let before = makeDescriptor(id: id, service: "example.com", hasTOTP: true)
        let adapter = FakeCredentialIdentityStoreAdapter(
            passwords: [AutoFillPasswordIdentity(descriptor: before)],
            oneTimeCodes: [AutoFillOneTimeCodeIdentity(descriptor: before)]
        )
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)
        let after = makeDescriptor(id: id, service: "example.com", hasTOTP: false)

        try await synchronizer.reconcile(descriptors: [after])

        let operations = await adapter.operations()
        #expect(operations.savedPasswords.isEmpty)
        #expect(operations.removedPasswords.isEmpty)
        #expect(operations.savedOneTimeCodes.isEmpty)
        #expect(operations.removedOneTimeCodes == [AutoFillOneTimeCodeIdentity(descriptor: before)])
    }

    @Test("adds updates and removes password and code identities independently")
    func independentlyReconcilesEachType() async throws {
        let updatedID = UUID()
        let removedID = UUID()
        let addedID = UUID()
        let desiredUpdated = makeDescriptor(
            id: updatedID,
            title: "Updated title",
            username: "updated@example.com",
            service: "updated.example",
            hasTOTP: true
        )
        let staleDescriptor = makeDescriptor(id: removedID, service: "stale.example", hasTOTP: true)
        let addedDescriptor = makeDescriptor(id: addedID, service: "added.example", hasTOTP: true)
        let adapter = FakeCredentialIdentityStoreAdapter(
            passwords: [
                AutoFillPasswordIdentity(
                    descriptorID: updatedID,
                    serviceIdentifier: "old.example",
                    username: "old@example.com"
                ),
                AutoFillPasswordIdentity(descriptor: staleDescriptor)
            ],
            oneTimeCodes: [
                AutoFillOneTimeCodeIdentity(
                    descriptorID: updatedID,
                    serviceIdentifier: "updated.example",
                    label: "Old title"
                ),
                AutoFillOneTimeCodeIdentity(descriptor: staleDescriptor)
            ]
        )
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)

        try await synchronizer.reconcile(descriptors: [desiredUpdated, addedDescriptor])

        let operations = await adapter.operations()
        #expect(Set(operations.savedPasswords) == [
            AutoFillPasswordIdentity(descriptor: desiredUpdated),
            AutoFillPasswordIdentity(descriptor: addedDescriptor)
        ])
        #expect(operations.removedPasswords == [AutoFillPasswordIdentity(descriptor: staleDescriptor)])
        #expect(Set(operations.savedOneTimeCodes) == [
            AutoFillOneTimeCodeIdentity(descriptor: desiredUpdated),
            AutoFillOneTimeCodeIdentity(descriptor: addedDescriptor)
        ])
        #expect(operations.removedOneTimeCodes == [AutoFillOneTimeCodeIdentity(descriptor: staleDescriptor)])
    }

    private func makeDescriptor(
        id: UUID,
        title: String = "Example",
        username: String = "person@example.com",
        service: String,
        hasTOTP: Bool
    ) -> AutoFillCredentialDescriptor {
        AutoFillCredentialDescriptor(
            id: id,
            vaultID: "vault",
            itemID: "item",
            shareID: "share",
            title: title,
            username: username,
            serviceIdentifier: service,
            hasTOTP: hasTOTP
        )
    }
}

private actor FakeCredentialIdentityStoreAdapter: AutoFillCredentialIdentityStoreAdapting {
    struct Operations: Sendable {
        var savedPasswords: [AutoFillPasswordIdentity] = []
        var removedPasswords: [AutoFillPasswordIdentity] = []
        var savedOneTimeCodes: [AutoFillOneTimeCodeIdentity] = []
        var removedOneTimeCodes: [AutoFillOneTimeCodeIdentity] = []
    }

    private var passwords: [AutoFillPasswordIdentity]
    private var oneTimeCodes: [AutoFillOneTimeCodeIdentity]
    private var recorded = Operations()

    init(
        passwords: [AutoFillPasswordIdentity] = [],
        oneTimeCodes: [AutoFillOneTimeCodeIdentity] = []
    ) {
        self.passwords = passwords
        self.oneTimeCodes = oneTimeCodes
    }

    func passwordIdentities() async throws -> [AutoFillPasswordIdentity] { passwords }
    func oneTimeCodeIdentities() async throws -> [AutoFillOneTimeCodeIdentity] { oneTimeCodes }

    func savePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws {
        recorded.savedPasswords.append(contentsOf: identities)
    }

    func removePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws {
        recorded.removedPasswords.append(contentsOf: identities)
    }

    func saveOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws {
        recorded.savedOneTimeCodes.append(contentsOf: identities)
    }

    func removeOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws {
        recorded.removedOneTimeCodes.append(contentsOf: identities)
    }

    func operations() -> Operations { recorded }
}
