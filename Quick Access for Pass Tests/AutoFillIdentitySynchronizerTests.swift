import AuthenticationServices
import Foundation
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill identity synchronization", .timeLimit(.minutes(1)))
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

    @Test("replacement or reset waits for actual native save completion", arguments: [false, true], [false, true])
    func joinsNativeSaveBeforeReplacement(cancelOlder: Bool, resetDesired: Bool) async throws {
        let nativeSave = OwnershipPause()
        let queuedOrFinished = SyncOrderingSignal()
        let adapter = OrderedCredentialIdentityStore(firstSavePause: nativeSave, secondSaveFinished: queuedOrFinished)
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter, onReconciliationQueued: { queuedOrFinished.signal() })
        let authority = SyncOperationAuthority()
        let older = authority.beginOperation()
        let id = UUID()
        let before = makeDescriptor(id: id, username: "older", service: "synthetic.example", hasTOTP: false)
        let after = makeDescriptor(id: id, username: "newer", service: "synthetic.example", hasTOTP: false)
        let oldTask = Task {
            try await synchronizer.reconcile(descriptors: [before], isCurrent: { older.isCurrent })
        }
        await nativeSave.waitUntilEntered()
        let newer = authority.beginOperation()
        if cancelOlder { oldTask.cancel() }
        let desired = resetDesired ? [] : [after]
        let newTask = Task {
            defer { queuedOrFinished.signal() }
            try await synchronizer.reconcile(descriptors: desired, isCurrent: { newer.isCurrent })
        }
        // With serialization, the queue probe fires. Without it, newer completion
        // fires this signal instead. Either case is deterministic, without sleeps.
        await queuedOrFinished.wait()
        #expect(await adapter.passwordReadCount() == 1)
        await nativeSave.finish()
        await #expect(throws: CancellationError.self) { try await oldTask.value }
        try await newTask.value
        #expect(try await adapter.passwordIdentities() == desired.map(AutoFillPasswordIdentity.init(descriptor:)))
    }

    @Test("a cancelled queued caller cannot release an older native save or block its successor")
    func cancelledWaiterRetainsNativeQueueOwnership() async throws {
        let nativeSave = OwnershipPause()
        let firstQueued = SyncOrderingSignal()
        let secondQueued = SyncOrderingSignal()
        let queued = Mutex(0)
        let adapter = OrderedCredentialIdentityStore(firstSavePause: nativeSave)
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter, onReconciliationQueued: {
            let count = queued.withLock { count in
                count += 1
                return count
            }
            if count == 1 { firstQueued.signal() }
            if count == 2 { secondQueued.signal() }
        })
        let authority = SyncOperationAuthority()
        let older = authority.beginOperation()
        let descriptor = makeDescriptor(id: UUID(), service: "synthetic.example", hasTOTP: false)
        let oldTask = Task { try await synchronizer.reconcile(descriptors: [descriptor], isCurrent: { older.isCurrent }) }
        await nativeSave.waitUntilEntered()
        let middle = authority.beginOperation()
        let middleTask = Task { try await synchronizer.reconcile(descriptors: [], isCurrent: { middle.isCurrent }) }
        await firstQueued.wait()
        middleTask.cancel()
        let newer = authority.beginOperation()
        let newTask = Task { try await synchronizer.reconcile(descriptors: [], isCurrent: { newer.isCurrent }) }
        await secondQueued.wait()
        #expect(await adapter.passwordReadCount() == 1)
        await nativeSave.finish()
        await #expect(throws: CancellationError.self) { try await oldTask.value }
        await #expect(throws: CancellationError.self) { try await middleTask.value }
        try await newTask.value
        #expect(await adapter.passwordReadCount() == 2)
        #expect(try await adapter.passwordIdentities().isEmpty)
    }

    @Test("supersession during a native read prevents subsequent mutation")
    func rechecksFreshnessAfterNativeRead() async throws {
        let nativeRead = OwnershipPause()
        let adapter = OrderedCredentialIdentityStore(passwordReadPause: nativeRead)
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)
        let authority = SyncOperationAuthority()
        let operation = authority.beginOperation()
        let descriptor = makeDescriptor(id: UUID(), service: "synthetic.example", hasTOTP: true)
        let task = Task {
            try await synchronizer.reconcile(descriptors: [descriptor], isCurrent: { operation.isCurrent })
        }
        await nativeRead.waitUntilEntered()
        authority.invalidate()
        await nativeRead.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await adapter.passwordSaveCount() == 0)
    }

    @Test("disabled AutoFill skips all identity access and reconciles after re-enabling")
    func skipsDisabledStoreAndReconcilesWhenEnabled() async throws {
        let adapter = ConfigurableAutoFillIdentityStore(enabled: false)
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)
        let descriptor = makeDescriptor(id: UUID(), service: "example.com", hasTOTP: true)

        try await synchronizer.reconcile(descriptors: [descriptor])
        #expect(await adapter.operations() == [.state])

        await adapter.setEnabled(true)
        try await synchronizer.reconcile(descriptors: [descriptor])
        #expect(try await adapter.passwordIdentities() == [AutoFillPasswordIdentity(descriptor: descriptor)])
        #expect(try await adapter.oneTimeCodeIdentities() == [AutoFillOneTimeCodeIdentity(descriptor: descriptor)])
    }

    @Test("disabling AutoFill during any mutation stops reconciliation without error", arguments: [
        ConfigurableAutoFillIdentityStore.Operation.savePasswords, .removePasswords, .saveCodes, .removeCodes
    ])
    func toleratesStoreDisabledDuringMutation(failureAt: ConfigurableAutoFillIdentityStore.Operation) async throws {
        let stale = makeDescriptor(id: UUID(), service: "stale.example", hasTOTP: true)
        let desired = makeDescriptor(id: UUID(), service: "desired.example", hasTOTP: true)
        let adapter = ConfigurableAutoFillIdentityStore(
            passwords: [AutoFillPasswordIdentity(descriptor: stale)],
            codes: [AutoFillOneTimeCodeIdentity(descriptor: stale)], failureAt: failureAt
        )
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)

        try await synchronizer.reconcile(descriptors: [desired])
        #expect(await adapter.operations().last == failureAt)
    }

    @Test("unexpected identity-store errors still propagate", arguments: [
        NSError(domain: ASCredentialIdentityStoreErrorDomain, code: ASCredentialIdentityStoreError.Code.internalError.rawValue),
        NSError(domain: ASCredentialIdentityStoreErrorDomain, code: ASCredentialIdentityStoreError.Code.storeBusy.rawValue),
        NSError(domain: "unrelated.test.error", code: 1)
    ])
    func propagatesUnexpectedErrors(error: NSError) async {
        let adapter = ConfigurableAutoFillIdentityStore(failureAt: .savePasswords, failure: error)
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)
        let descriptor = makeDescriptor(id: UUID(), service: "example.com", hasTOTP: false)

        await #expect(throws: error) { try await synchronizer.reconcile(descriptors: [descriptor]) }
    }

    @Test("disabled state does not hide cancellation or supersession during the state read", arguments: [false, true])
    func rechecksFreshnessAfterDisabledStateRead(cancel: Bool) async throws {
        let pause = OwnershipPause()
        let adapter = ConfigurableAutoFillIdentityStore(enabled: false, pauseAt: .state, pause: pause)
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)
        let authority = SyncOperationAuthority()
        let operation = authority.beginOperation()
        let task = Task { try await synchronizer.reconcile(descriptors: [], isCurrent: { operation.isCurrent }) }
        await pause.waitUntilEntered()
        if cancel { task.cancel() } else { authority.invalidate() }
        await pause.finish()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await adapter.operations() == [.state])
    }

    @Test("store-disabled mutation error does not hide cancellation or supersession", arguments: [false, true])
    func rechecksFreshnessBeforeIgnoringDisabledError(cancel: Bool) async throws {
        let pause = OwnershipPause()
        let adapter = ConfigurableAutoFillIdentityStore(failureAt: .savePasswords, pauseAt: .savePasswords, pause: pause)
        let synchronizer = AutoFillIdentitySynchronizer(adapter: adapter)
        let authority = SyncOperationAuthority()
        let operation = authority.beginOperation()
        let descriptor = makeDescriptor(id: UUID(), service: "example.com", hasTOTP: true)
        let task = Task { try await synchronizer.reconcile(descriptors: [descriptor], isCurrent: { operation.isCurrent }) }
        await pause.waitUntilEntered()
        if cancel { task.cancel() } else { authority.invalidate() }
        await pause.finish()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await adapter.operations().last == .savePasswords)
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

private actor OrderedCredentialIdentityStore: AutoFillCredentialIdentityStoreAdapting {
    private var passwords: [AutoFillPasswordIdentity] = []
    private var reads = 0
    private var saves = 0
    private let firstSavePause: OwnershipPause?
    private let secondSaveFinished: SyncOrderingSignal?
    private let passwordReadPause: OwnershipPause?

    init(firstSavePause: OwnershipPause? = nil, secondSaveFinished: SyncOrderingSignal? = nil,
         passwordReadPause: OwnershipPause? = nil) {
        self.firstSavePause = firstSavePause
        self.secondSaveFinished = secondSaveFinished
        self.passwordReadPause = passwordReadPause
    }

    func isEnabled() async -> Bool { true }
    func passwordReadCount() -> Int { reads }
    func passwordSaveCount() -> Int { saves }
    func passwordIdentities() async throws -> [AutoFillPasswordIdentity] {
        reads += 1
        await passwordReadPause?.suspend()
        return passwords
    }
    func oneTimeCodeIdentities() async throws -> [AutoFillOneTimeCodeIdentity] { [] }
    func savePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws {
        saves += 1
        let call = saves
        if call == 1 { await firstSavePause?.suspend() }
        passwords = identities
        if call == 2 { secondSaveFinished?.signal() }
    }
    func removePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws {
        let removed = Set(identities)
        passwords.removeAll { removed.contains($0) }
    }
    func saveOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws {}
    func removeOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws {}
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

    func isEnabled() async -> Bool { true }
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
