import Foundation
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Whole-sync writer ordering", .timeLimit(.minutes(1)))
struct SyncOperationOrderingTests {
    @Test("replacement and invalidation revoke only older whole-sync tokens")
    func authorityFreshness() {
        let authority = SyncOperationAuthority()
        let older = authority.beginOperation()
        #expect(older.isCurrent)
        let newer = authority.beginOperation()
        #expect(!older.isCurrent)
        #expect(newer.isCurrent)
        authority.invalidate()
        #expect(!newer.isCurrent)
    }

    @Test("an older queued submission cannot replace newer committed metadata")
    func rejectsSupersededQueuedMetadata() async throws {
        let pause = OwnershipPause()
        let first = Mutex(true)
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8), offlineMutationTesting:
            OfflineMutationTesting(afterAdmission: { _ in
                let shouldPause = first.withLock { first in
                    defer { first = false }
                    return first
                }
                if shouldPause { await pause.suspend() }
            })
        )
        let older = database.beginSyncOperation()
        let oldWrite = Task {
            try await database.synchronizeMetadata(
                vaults: [vault], items: [item(title: "Older")], descriptors: [], operation: older
            )
        }
        await pause.waitUntilEntered()
        let newer = database.beginSyncOperation()
        _ = try await database.synchronizeMetadata(
            vaults: [vault], items: [item(title: "Newer")], descriptors: [], operation: newer
        )
        await pause.finish()
        await #expect(throws: CancellationError.self) { try await oldWrite.value }
        #expect(try database.allActiveItems().map(\.title) == ["Newer"])
    }

    @Test("already-admitted writer completion precedes replacement and is not undone by late cancellation")
    func joinsAlreadyAdmittedCommit() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let writerGate = SyncOrderingWriterGate()
        let committed = SyncOrderingSignal()
        let callerReturn = OwnershipPause()
        let older = database.beginSyncOperation()
        let oldWrite = Task {
            let result = try await database.synchronizeMetadata(
                vaults: [vault], items: [item(title: "Older")], descriptors: [], operation: older,
                beforeDescriptorWrite: { writerGate.hold() }
            )
            committed.signal()
            await callerReturn.suspend()
            return result
        }
        await writerGate.entered.wait()
        let newer = database.beginSyncOperation()
        let newWrite = Task {
            try await database.synchronizeMetadata(
                vaults: [vault], items: [item(title: "Newer")], descriptors: [], operation: newer
            )
        }
        writerGate.open()
        await committed.wait()
        await callerReturn.waitUntilEntered()
        oldWrite.cancel()
        await callerReturn.finish()
        _ = try await oldWrite.value
        _ = try await newWrite.value
        #expect(try database.allActiveItems().map(\.title) == ["Newer"])
    }

    @Test("both metadata clearing APIs invalidate existing sync operations", arguments: [false, true])
    func resetInvalidatesAuthority(synchronous: Bool) async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic".utf8))
        let operation = database.beginSyncOperation()
        if synchronous { try database.clearAll() } else { try await database.clearMetadata() }
        #expect(!operation.isCurrent)
    }

    private var vault: PassVault { PassVault(id: "vault", name: "Synthetic", shareId: "share") }

    private func item(title: String) -> PassItem {
        PassItem(id: "item", vaultId: "vault", title: title, itemType: .note, subtitle: "", url: nil,
                 hasTOTP: false, state: "Active", createTime: .distantPast, modifyTime: .distantFuture,
                 useCount: 0, lastUsedAt: nil)
    }
}
