import GRDB
import Synchronization

/// Immutable, metadata-only ordering probes. No hooks are installed in production.
nonisolated struct OfflineMutationTesting: Sendable {
    let afterAdmission: (@Sendable (OfflineReleaseMutationScope) async -> Void)?
    let admissionMarker: (@Sendable (OfflineReleaseMutationScope) -> Void)?

    init(afterAdmission: (@Sendable (OfflineReleaseMutationScope) async -> Void)? = nil,
         admissionMarker: (@Sendable (OfflineReleaseMutationScope) -> Void)? = nil) {
        self.afterAdmission = afterAdmission
        self.admissionMarker = admissionMarker
    }
}

nonisolated extension DatabaseManager {
    func writeOfflineMutation<Value: Sendable>(
        submissionScope: OfflineReleaseMutationScope,
        updates: @escaping @Sendable (Database) throws -> OfflineMutationUpdate<Value>
    ) throws -> Value {
        let mutation = offlineReleaseAuthority.beginMutation(submissionScope)
        offlineMutationTesting?.admissionMarker?(submissionScope)
        let settlement = MutationSettlement(authority: offlineReleaseAuthority, mutation: mutation)
        defer { settlement.finish(.rolledBack) }
        return try writer.writeWithoutTransaction { db in
            try Self.performOfflineMutation(in: db, settlement: settlement, updates: updates)
        }
    }

    func writeOfflineMutation<Value: Sendable>(
        submissionScope: OfflineReleaseMutationScope,
        beforeWrite: (@Sendable () async -> Void)? = nil,
        updates: @escaping @Sendable (Database) throws -> OfflineMutationUpdate<Value>
    ) async throws -> Value {
        let mutation = offlineReleaseAuthority.beginMutation(submissionScope)
        offlineMutationTesting?.admissionMarker?(submissionScope)
        let settlement = MutationSettlement(authority: offlineReleaseAuthority, mutation: mutation)
        // GRDB awaits writer completion even when cancelled. Once admitted, only
        // the writer settles; this fallback covers hooks/unsubmitted access failures.
        defer { settlement.finish(.rolledBack) }
        await offlineMutationTesting?.afterAdmission?(submissionScope)
        await beforeWrite?()
        try Task.checkCancellation()
        return try await writer.writeWithoutTransaction { db in
            try Self.performOfflineMutation(in: db, settlement: settlement, updates: updates)
        }
    }

    private static func performOfflineMutation<Value: Sendable>(
        in db: Database,
        settlement: MutationSettlement,
        updates: (Database) throws -> OfflineMutationUpdate<Value>
    ) throws -> Value {
        do {
            guard !db.isInsideTransaction else { throw OfflinePersistenceError.persistenceFailed }
            var result: TransactionValue<Value> = .missing
            try db.inTransaction {
                result = .value(try updates(db))
                return .commit
            }
            guard case .value(let update) = result else { throw OfflinePersistenceError.persistenceFailed }
            // inTransaction has returned: COMMIT, not just the update body, succeeded.
            settlement.finish(.committed(manualPromotions: update.manualPromotions))
            return update.value
        } catch {
            settlement.finish(.rolledBack)
            throw error
        }
    }
}

nonisolated private enum TransactionValue<Value: Sendable> {
    case missing
    case value(OfflineMutationUpdate<Value>)
}

/// Exactly one settlement owner, including failure before GRDB invokes the body.
nonisolated private final class MutationSettlement: Sendable {
    private let authority: OfflineReleaseAuthority
    private let mutation: OfflineReleaseMutation
    private let finished = Mutex(false)

    init(authority: OfflineReleaseAuthority, mutation: OfflineReleaseMutation) {
        self.authority = authority
        self.mutation = mutation
    }

    func finish(_ outcome: OfflineReleaseMutationOutcome) {
        finished.withLock { finished in
            guard !finished else { return }
            authority.finishMutation(mutation, outcome: outcome)
            finished = true
        }
    }
}
