import Foundation
@testable import Quick_Access_for_Pass

/// Metadata-only controlled work, including a separately gated cancellation cleanup.
actor OfflineWorkRecorder {
    private var active = 0
    private var maximumActive = 0
    private var completed = 0
    private var calls: [OfflineSnapshotKey: Int] = [:]
    private var candidates: [OfflineSnapshotWorkCandidate] = []
    private var released = false
    private var cleanupReleased: Bool
    private var cancellationCount = 0
    private let failingKeys: Set<OfflineSnapshotKey>
    private var workWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var startWaiters: [UUID: (Int, CheckedContinuation<Void, any Error>)] = [:]
    private var cancellationWaiters: [UUID: (Int, CheckedContinuation<Void, any Error>)] = [:]
    private var cleanupWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(failingKeys: Set<OfflineSnapshotKey> = [], holdCancelledCleanup: Bool = false) {
        self.failingKeys = failingKeys
        cleanupReleased = !holdCancelledCleanup
    }

    nonisolated private enum Signal: Sendable { case work, started(Int), cancelled(Int) }

    func run(_ candidate: OfflineSnapshotWorkCandidate) async throws {
        active += 1
        maximumActive = max(maximumActive, active)
        calls[candidate.key, default: 0] += 1
        candidates.append(candidate)
        resumeSatisfiedSignals()
        defer { active -= 1 }
        do {
            if !released { try await suspend(.work) }
            try Task.checkCancellation()
            if failingKeys.contains(candidate.key) { throw CLIError.commandFailed("fixture diagnostic must not escape") }
            completed += 1
        } catch is CancellationError {
            cancellationCount += 1
            resumeSatisfiedSignals()
            if !cleanupReleased {
                // Deliberately non-cancellable cleanup: invalidation must join it.
                await withCheckedContinuation { cleanupWaiters[UUID()] = $0 }
            }
            throw CancellationError()
        }
    }

    func waitForStartedCount(_ count: Int) async throws {
        if candidates.count < count { try await suspend(.started(count)) }
    }

    func waitForCancellationCount(_ count: Int) async throws {
        if cancellationCount < count { try await suspend(.cancelled(count)) }
    }

    func releaseCancelledCleanup() {
        cleanupReleased = true
        let pending = cleanupWaiters
        cleanupWaiters.removeAll()
        for continuation in pending.values { continuation.resume() }
    }

    func releaseAll() {
        released = true
        releaseCancelledCleanup()
        let pending = workWaiters
        workWaiters.removeAll()
        for continuation in pending.values { continuation.resume() }
    }

    /// Called after owned tasks are joined, to drain even unsatisfied signal waits.
    func drain() {
        releaseAll()
        let starts = startWaiters
        let cancellations = cancellationWaiters
        startWaiters.removeAll()
        cancellationWaiters.removeAll()
        for (_, continuation) in starts.values { continuation.resume(throwing: CancellationError()) }
        for (_, continuation) in cancellations.values { continuation.resume(throwing: CancellationError()) }
    }

    func maximumActiveCount() -> Int { maximumActive }
    func activeCount() -> Int { active }
    func completedCount() -> Int { completed }
    func startedCount() -> Int { candidates.count }
    func maximumCallsPerKey() -> Int { calls.values.max() ?? 0 }
    func calls(for key: OfflineSnapshotKey) -> Int { calls[key, default: 0] }
    func startedCandidates() -> [OfflineSnapshotWorkCandidate] { candidates }

    private func suspend(_ signal: Signal) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    switch signal {
                    case .work: workWaiters[id] = continuation
                    case .started(let count): startWaiters[id] = (count, continuation)
                    case .cancelled(let count): cancellationWaiters[id] = (count, continuation)
                    }
                }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    private func cancel(_ id: UUID) {
        let continuation = workWaiters.removeValue(forKey: id)
            ?? startWaiters.removeValue(forKey: id)?.1
            ?? cancellationWaiters.removeValue(forKey: id)?.1
        continuation?.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedSignals() {
        let starts = startWaiters.filter { $0.value.0 <= candidates.count }
        for (id, _) in starts {
            startWaiters.removeValue(forKey: id)?.1.resume()
        }
        let cancellations = cancellationWaiters.filter { $0.value.0 <= cancellationCount }
        for (id, _) in cancellations {
            cancellationWaiters.removeValue(forKey: id)?.1.resume()
        }
    }
}
