import Foundation
@testable import Quick_Access_for_Pass

/// Retains only the latest display metadata, never an exact-emission-count contract.
actor IncrementalPoolObservationRecorder {
    private struct Waiter {
        let matches: @Sendable (OfflinePresentationSnapshot) -> Bool
        let continuation: CheckedContinuation<OfflinePresentationSnapshot, Error>
    }
    private var latest: OfflinePresentationSnapshot?
    private var waiters: [UUID: Waiter] = [:]
    private var ended = false
    private var emissions = 0

    func receive(_ snapshot: OfflinePresentationSnapshot) {
        latest = snapshot
        emissions += 1
        let completed = waiters.filter { $0.value.matches(snapshot) }
        for (id, waiter) in completed {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: snapshot)
        }
    }
    func finish() {
        ended = true
        let remaining = waiters.values
        waiters.removeAll()
        for waiter in remaining { waiter.continuation.resume(throwing: CancellationError()) }
    }
    func emissionCount() -> Int { emissions }
    func wait(matching predicate: @escaping @Sendable (OfflinePresentationSnapshot) -> Bool) async throws -> OfflinePresentationSnapshot {
        try Task.checkCancellation()
        if let latest, predicate(latest) { return latest }
        guard !ended else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = Waiter(matches: predicate, continuation: continuation) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}
