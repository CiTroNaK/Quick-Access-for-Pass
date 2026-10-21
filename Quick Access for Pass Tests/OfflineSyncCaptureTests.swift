import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline sync capture and freshness")
struct OfflineSyncCaptureTests {
    @Test func selectedMissingCopyProducesGenerationBoundMetadataOnlyWork() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let selection = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 1)
        let work = try #require(try await fixture.work(for: capture).first)
        #expect(work.key.itemId == "item")
        #expect(work.shareID == "share")
        #expect(work.itemType == .login)
        #expect(work.metadataProof.operationID == capture.operation.id)
        #expect(work.capturedPendingRequestID == nil)
        guard case .selected(let selected, _, let metadata) = work.ownership else {
            Issue.record("Expected existing-selection ownership")
            return
        }
        #expect(selected == selection)
        #expect(work.metadataProof.metadataGeneration == metadata)
    }

    @Test func matchingHealthyCopySkipsWithoutReservationOrWriterChanges() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        try await fixture.cache()
        let capture = try await fixture.capture()
        let before = try await fixture.database.writer.writeWithoutTransaction {
            try Int.fetchOne($0, sql: "SELECT total_changes()")
        }
        let work = try await fixture.work(for: capture)
        let after = try await fixture.database.writer.writeWithoutTransaction {
            try Int.fetchOne($0, sql: "SELECT total_changes()")
        }
        #expect(work.isEmpty)
        #expect(before == after)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineItems WHERE pendingRequestId IS NOT NULL") == 0)
    }

    @Test(arguments: ["failed", "missing", "invalidRevision", "unknownFormat", "missingBaseline", "invalidBaseline", "dirtyMetadata"])
    func unusableOrDirtyCopyRequiresWork(reason: String) async throws {
        let fixture = try OfflineSyncPlanningFixture()
        try await fixture.cache()
        try await fixture.database.writer.write { db in
            switch reason {
            case "failed": try db.execute(sql: "UPDATE offlineItems SET cacheStatus = 'failed'")
            case "missing": try db.execute(sql: "DELETE FROM offlineSnapshots")
            case "invalidRevision": try db.execute(sql: "UPDATE offlineSnapshots SET snapshotRevision = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'")
            case "unknownFormat": try db.execute(sql: "UPDATE offlineSnapshots SET schemaVersion = 2")
            case "missingBaseline": try db.execute(sql: "UPDATE offlineSnapshots SET sourceModifyTime = NULL")
            case "invalidBaseline": try db.execute(sql: "UPDATE offlineSnapshots SET sourceModifyTime = 'invalid'")
            default: try db.execute(sql: "UPDATE offlineItems SET metadataGeneration = ?", arguments: [UUID().uuidString])
            }
        }
        let capture = try await fixture.capture()
        #expect(try await fixture.work(for: capture).count == 1)
    }

    @Test func submillisecondMarkersSkipOnlyTheIdenticalVersionDespiteRoundedOrdinaryMetadata() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let raw = "1970-01-01T00:00:02.123456Z"
        let original = try #require(OfflineSourceModificationTime.parse(raw))
        try fixture.database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault", modifyTime: original)])
        try await fixture.cache(sourceTime: raw)
        let capture = try await fixture.capture()
        var proofs = try await fixture.proofs(for: capture)
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let base = try #require(proofs[key])
        proofs[key] = OfflineSyncedMetadataProof(
            operationID: capture.operation.id, item: offlineTestMetadata(id: "item", vaultID: "vault", modifyTime: original),
            shareID: base.shareID, descriptorInputs: base.descriptorInputs, metadataGeneration: base.metadataGeneration
        )
        #expect(try await fixture.work(for: capture, proofs: proofs, sourceTimes: ["item": original]).isEmpty)
        #expect(try await fixture.work(for: capture, proofs: proofs, sourceTimes: [:]).count == 1)
        let changed = try #require(OfflineSourceModificationTime.parse("1970-01-01T00:00:02.123457Z"))
        proofs[key] = OfflineSyncedMetadataProof(
            operationID: capture.operation.id, item: offlineTestMetadata(id: "item", vaultID: "vault", modifyTime: changed),
            shareID: base.shareID, descriptorInputs: base.descriptorInputs, metadataGeneration: base.metadataGeneration
        )
        #expect(try await fixture.work(for: capture, proofs: proofs, sourceTimes: ["item": changed]).count == 1)
    }

    @Test func foreignOperationProofDoesNotAuthorizeCurrentCapture() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        var proofs = try await fixture.proofs(for: capture)
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let valid = try #require(proofs[key])
        #expect(try await fixture.work(for: capture, proofs: proofs).count == 1)
        proofs[key] = OfflineSyncedMetadataProof(operationID: UUID(), item: valid.item, shareID: valid.shareID,
                                                descriptorInputs: valid.descriptorInputs, metadataGeneration: valid.metadataGeneration)
        #expect(try await fixture.work(for: capture, proofs: proofs).isEmpty)
    }

    @Test func obsoleteOperationCannotCreatePersistedAdmission() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let obsolete = fixture.database.beginSyncOperation()
        _ = fixture.database.beginSyncOperation()
        await #expect(throws: OfflinePersistenceError.identityChanged) {
            _ = try await fixture.repository.beginSyncCapture(operation: obsolete, lifecycleGeneration: UUID())
        }
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
    }

    @Test func actualSuccessfulSourceBaselineRetainsSubmillisecondPrecision() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let raw = "1970-01-01T00:00:02.123456Z"
        try await fixture.cache(sourceTime: raw)
        let expected = try #require(OfflineSourceModificationTime.parse(raw))
        let stored = try await fixture.database.reader.read {
            try Date.fetchOne($0, sql: "SELECT sourceModifyTime FROM offlineSnapshots WHERE itemId = 'item'")
        }
        #expect(stored == expected)
    }

    @Test func unknownIncomingSourceAlwaysRefreshes() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        try await fixture.cache()
        let capture = try await fixture.capture()
        #expect(try await fixture.work(for: capture, sourceTimes: [:]).count == 1)
    }

    @Test(arguments: [1.0, 4.0])
    func regressedOrAdvancedSourceRefreshes(incoming: Double) async throws {
        let fixture = try OfflineSyncPlanningFixture()
        try await fixture.cache()
        try fixture.database.upsertItems([offlineTestMetadata(id: "item", vaultID: "vault", modifyTime: Date(timeIntervalSince1970: incoming))])
        let capture = try await fixture.capture()
        #expect(try await fixture.work(for: capture).count == 1)
    }

    @Test func oldProofCannotAdoptNewMetadataGenerationOrSourceFields() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        let proof = try await fixture.proofs(for: capture)
        try await fixture.database.writer.write {
            try $0.execute(sql: "UPDATE offlineItems SET metadataGeneration = ?", arguments: [UUID().uuidString])
        }
        #expect(try await fixture.work(for: capture, proofs: proof).isEmpty)
        let fresh = try await fixture.proofs(for: capture)
        try await fixture.database.writer.write { try $0.execute(sql: "UPDATE items SET title = 'Changed without changing time'") }
        #expect(try await fixture.work(for: capture, proofs: fresh).isEmpty)
    }

    @Test func pendingExplicitRequestAtCaptureIsNeverStolenEvenAfterCompletion() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .selection))
        let capture = try await fixture.capture()
        #expect(try await fixture.work(for: capture).isEmpty)
        try await fixture.repository.finishRequest(request, failed: true)
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test func completedLaterRetryCannotHideBehindNullPendingOwner() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        try await fixture.cache()
        let capture = try await fixture.capture()
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
        try await fixture.repository.finishRequest(request, failed: true)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineItems WHERE pendingRequestId IS NOT NULL") == 0)
        #expect(try await fixture.work(for: capture).isEmpty)
    }

    @Test func endingOldCaptureDoesNotDeleteSuccessorAndOldOperationCannotPlan() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let old = try await fixture.capture()
        let new = try await fixture.capture()
        #expect(try await fixture.work(for: old).isEmpty)
        try await fixture.repository.endSyncCapture(old)
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 1)
        #expect(try await fixture.work(for: new).count == 1)
        try await fixture.repository.endSyncCapture(new)
        #expect(try await fixture.work(for: new).isEmpty)
    }

    @Test func mismatchedLifecycleHandleIsNotPersistedAuthority() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let capture = try await fixture.capture()
        let forged = OfflineSyncCapture(id: capture.id, operation: capture.operation, lifecycleGeneration: UUID())
        #expect(try await fixture.work(for: forged).isEmpty)
        try await fixture.repository.endSyncCapture(forged)
        #expect(try await fixture.work(for: capture).count == 1)
    }

    @Test func purgeAndRecoveryAbandonCapturesWithoutRecreatingSelections() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        _ = try await fixture.repository.selectItemManually(itemID: "item", vaultID: "vault", shareID: "share")
        let beforePurge = try await fixture.capture()
        try await fixture.repository.purge()
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
        #expect(try await fixture.work(for: beforePurge).isEmpty)
        let orphan = try await fixture.capture()
        try await fixture.repository.recoverAbandonedRequests()
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
        #expect(try await fixture.work(for: orphan).isEmpty)
    }

    @Test func metadataResetInvalidatesCaptureAndDropsItsMetadata() async throws {
        let fixture = try OfflineSyncPlanningFixture()
        let capture = try await fixture.capture()
        try await fixture.database.clearMetadata()
        #expect(try await fixture.scalar("SELECT COUNT(*) FROM offlineSyncCaptures") == 0)
        #expect(try await fixture.work(for: capture).isEmpty)
    }
}
