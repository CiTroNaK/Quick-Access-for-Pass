import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Incremental metadata synchronization")
struct IncrementalMetadataSynchronizationTests {
    private let vaults = [PassVault(id: "vault", name: "Vault", shareId: "share")]

    @Test(arguments: [1, 40, 1300])
    func unchangedSyncHasBoundedReadsAndZeroMetadataUpdates(count: Int) async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("synthetic-incremental-metadata".utf8))
        let items = (0..<count).map { offlineTestMetadata(id: "item-\($0)", vaultID: "vault") }
        let inputs = items.map { incrementalDescriptor(itemID: $0.id) }
        let before = try database.syncMetadata(vaults: vaults, items: items, descriptors: inputs)
        try database.recordUsage(itemId: "item-0")
        let used = try #require(try database.allActiveItems().first { $0.id == "item-0" })
        let counter = MetadataWriteCounter()
        try counter.install(on: database)
        let operation = database.beginSyncOperation()
        let result = try await database.synchronizeMetadata(vaults: vaults, items: items, descriptors: inputs, operation: operation)
        let report = try counter.finish(on: database)
        print("Metadata sync metrics: items=\(count) SELECTs=\(report.selects) pointLookups=\(report.pointItemLookups) updatedRows=\(report.updates.values.reduce(0, +))")
        #expect(report.updates.values.reduce(0, +) == 0, "Unchanged sync updated rows: \(report.updates)")
        #expect(report.pointItemLookups == 0)
        let schemaReads = report.selectShapes.filter {
            $0.key.contains("FROM SQLITE_MASTER") || $0.key.contains("FROM SQLITE_TEMP_MASTER")
        }.values.reduce(0, +)
        #expect(schemaReads == 2)
        #expect(report.selects - schemaReads == 8)
        #expect(report.selects == 10, "Observed \(report.selects) SELECTs for \(count) items; unexpanded shapes: \(report.selectShapes)")
        #expect(Set(result.descriptors.map(\.id)) == Set(before.map(\.id)))
        let after = try #require(try database.allActiveItems().first { $0.id == "item-0" })
        #expect(after.useCount == used.useCount)
        #expect(after.lastUsedAt == used.lastUsedAt)
        #expect(result.offlineMetadataProofs.count == count)
        #expect(result.offlineMetadataProofs.values.allSatisfy { $0.operationID == operation.id && $0.shareID == "share" })
    }

    @Test(arguments: ["title", "username", "url", "fieldPresence", "additionalURL", "share", "usage"])
    func relevantSameTimeChangesAdvanceOnlyTheAffectedSelectedGeneration(change: String) async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try fixture.database.syncMetadata(vaults: vaults, items: [incrementalMetadata()], descriptors: [incrementalDescriptor()])
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let before = try generation(in: fixture.database)
        let title = change == "title" ? "Changed title" : "Offline example"
        let username = change == "username" ? "changed@example.test" : "person@example.test"
        let share = change == "share" ? "replacement-share" : "share"
        let item = incrementalMetadata(title: title, username: username,
                                       url: change == "url" ? "https://changed.example.test" : nil,
                                       fields: change == "fieldPresence" ? [.email] : [])
        var inputs = [incrementalDescriptor(title: title, username: username, share: share)]
        if change == "additionalURL" { inputs.append(incrementalDescriptor(service: "secondary.example.test")) }
        if change == "usage" { try fixture.database.recordUsage(itemId: "item") }
        let counter = MetadataWriteCounter()
        try counter.install(on: fixture.database)
        let operation = fixture.database.beginSyncOperation()
        let result = try await fixture.database.synchronizeMetadata(
            vaults: [PassVault(id: "vault", name: "Vault", shareId: share)], items: [item], descriptors: inputs, operation: operation
        )
        let report = try counter.finish(on: fixture.database)
        let after = try generation(in: fixture.database)
        if change == "usage" {
            #expect(after == before)
            #expect(report.updates["offlineItems", default: 0] == 0)
        } else {
            #expect(after != before)
            #expect(report.updates["offlineItems"] == 1)
        }
        let proof = try #require(result.offlineMetadataProofs.values.first)
        #expect(proof.metadataGeneration?.uuidString == after)
        #expect(proof.shareID == share)
        #expect(proof.descriptorInputs.count == inputs.count)
        if change == "title" { #expect(try fixture.database.searchItems(query: "Changed").map(\.id) == ["item"]) }
    }

    @Test(arguments: [false, true])
    func retainedItemWritersAdvanceGenerationWithoutPerItemLookup(replacement: Bool) async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let before = try generation(in: fixture.database)
        let counter = MetadataWriteCounter()
        try counter.install(on: fixture.database)
        if replacement { try fixture.database.syncItems([incrementalMetadata(title: "Changed")]) }
        else { try fixture.database.upsertItems([incrementalMetadata(title: "Changed")]) }
        let report = try counter.finish(on: fixture.database)
        #expect(try generation(in: fixture.database) != before)
        #expect(report.updates["offlineItems"] == 1)
        #expect(report.pointItemLookups == 0)
        #expect(try fixture.database.searchItems(query: "Changed").map(\.id) == ["item"])
    }

    @Test func descriptorFailureRollsBackItemAndGenerationTogether() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try fixture.database.syncMetadata(vaults: vaults, items: [incrementalMetadata()], descriptors: [incrementalDescriptor()])
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let before = try generation(in: fixture.database)
        let descriptors = try fixture.database.allAutoFillDescriptors()
        await #expect(throws: RollbackFailure.forced) {
            _ = try await fixture.database.synchronizeMetadata(
                vaults: vaults, items: [incrementalMetadata(title: "Changed")], descriptors: [incrementalDescriptor(title: "Changed")],
                operation: fixture.database.beginSyncOperation(), beforeDescriptorWrite: { throw RollbackFailure.forced }
            )
        }
        #expect(try generation(in: fixture.database) == before)
        #expect(try fixture.database.allAutoFillDescriptors() == descriptors)
        #expect(try fixture.database.allActiveItems().first?.title == "Offline example")
        #expect(try fixture.database.searchItems(query: "Changed").isEmpty)
    }

    @Test func transactionProofCannotBeReboundAfterRetainedWriterChangesMetadata() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        let result = try await fixture.database.synchronizeMetadata(
            vaults: vaults, items: [incrementalMetadata()], descriptors: [], operation: capture.operation
        )
        let proof = try #require(result.offlineMetadataProofs.values.first)
        #expect(proof.operationID == capture.operation.id)
        try fixture.database.upsertItems([incrementalMetadata(title: "Changed without a clock change")])
        #expect(proof.metadataGeneration?.uuidString != (try generation(in: fixture.database)))
        #expect(try await fixture.work(for: capture, proofs: result.offlineMetadataProofs).isEmpty)
    }

    @Test func additionalDescriptorURLDirtiesSameTimeCachedCopy() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try fixture.database.syncMetadata(vaults: vaults, items: [incrementalMetadata()], descriptors: [incrementalDescriptor()])
        try await fixture.cache()
        let capture = try await fixture.capture()
        let result = try await fixture.database.synchronizeMetadata(
            vaults: vaults, items: [incrementalMetadata()],
            descriptors: [incrementalDescriptor(), incrementalDescriptor(service: "secondary.example.test")], operation: capture.operation
        )
        #expect(try await fixture.work(for: capture, proofs: result.offlineMetadataProofs).count == 1)
    }

    @Test func unmaterializedMemberProofHasSourceContextButNoInventedSelectedGeneration() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        let capture = try await fixture.capture()
        let result = try await fixture.database.synchronizeMetadata(
            vaults: vaults, items: [incrementalMetadata()], descriptors: [], operation: capture.operation
        )
        let proof = try #require(result.offlineMetadataProofs.values.first)
        #expect(proof.metadataGeneration == nil)
        #expect(proof.shareID == "share")
        let work = try #require(try await fixture.work(for: capture, proofs: result.offlineMetadataProofs).first)
        guard case .vaultMember = work.ownership else { Issue.record("Expected vault-member ownership"); return }
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineItems") == 0)
    }

    @Test func ordinaryMillisecondRepresentationDoesNotDirtyAnIdenticalFractionalSource() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let time = try #require(OfflineSourceModificationTime.parse("2026-10-01T12:00:00.123456Z"))
        let item = incrementalMetadata(modifyTime: time)
        _ = try fixture.database.syncMetadata(vaults: vaults, items: [item], descriptors: [])
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let before = try generation(in: fixture.database)
        let counter = MetadataWriteCounter()
        try counter.install(on: fixture.database)
        let result = try await fixture.database.synchronizeMetadata(
            vaults: vaults, items: [item], descriptors: [], operation: fixture.database.beginSyncOperation()
        )
        let report = try counter.finish(on: fixture.database)
        #expect(report.updates.values.reduce(0, +) == 0)
        #expect(try generation(in: fixture.database) == before)
        #expect(result.offlineMetadataProofs.values.first?.item.modifyTime == time)
    }

    @Test func standaloneVaultWriterDistinguishesDisplayRenameFromSourceShareChange() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        let result = try await fixture.database.synchronizeMetadata(
            vaults: vaults, items: [incrementalMetadata()], descriptors: [], operation: capture.operation
        )
        let before = try generation(in: fixture.database)
        try fixture.database.upsertVaults([PassVault(id: "vault", name: "Renamed", shareId: "share")])
        #expect(try generation(in: fixture.database) == before)
        try fixture.database.upsertVaults([PassVault(id: "vault", name: "Renamed", shareId: "replacement-share")])
        #expect(try generation(in: fixture.database) != before)
        #expect(try await fixture.work(for: capture, proofs: result.offlineMetadataProofs).isEmpty)
    }

    @Test func ordinaryCallerWithoutOperationDoesNotMintBulkSourceEvidence() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let result = try await fixture.database.synchronizeMetadata(vaults: vaults, items: [incrementalMetadata()],
                                                                   descriptors: [incrementalDescriptor()])
        #expect(result.offlineMetadataProofs.isEmpty)
        #expect(result.descriptors.count == 1)
        #expect(try fixture.database.allActiveItems().count == 1)
    }

    private func generation(in database: DatabaseManager) throws -> String {
        try #require(try database.reader.read { try String.fetchOne($0, sql: "SELECT metadataGeneration FROM offlineItems WHERE itemId = 'item'") })
    }

    private enum RollbackFailure: Error { case forced }
}
