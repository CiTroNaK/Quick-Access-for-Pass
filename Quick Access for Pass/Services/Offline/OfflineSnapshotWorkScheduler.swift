import Foundation

/// Owns metadata-only snapshot work across every trigger, including cancellation cleanup.
actor OfflineSnapshotWorkScheduler {
    /// Bounded outcomes that never expose CLI diagnostics or captured secret values.
    nonisolated enum Failure: Error, Sendable, Equatable {
        case cancelled
        case unavailable
        case superseded
        case selectionSuspended
    }

    nonisolated private struct Identity: Hashable, Sendable {
        let vaultID: String
        let itemID: String

        init(_ key: OfflineSnapshotKey) {
            vaultID = key.vaultId
            itemID = key.itemId
        }
    }

    nonisolated private enum Outcome: Sendable {
        case success
        case failure(Failure)
    }

    nonisolated private struct Work {
        let id = UUID()
        let candidate: OfflineSnapshotWorkCandidate
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    nonisolated private struct ActiveWork {
        var work: Work
        let task: Task<Void, Never>
        var revoked: Failure?
    }

    private let run: @Sendable (OfflineSnapshotWorkCandidate) async throws -> Void
    private var pending: [Work] = []
    private var active: [Identity: ActiveWork] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var stopped = false

    /// The callback must recheck committed availability and reserve current policy
    /// and metadata in the repository before fetching; enqueueing grants no authority.
    init(run: @escaping @Sendable (OfflineSnapshotWorkCandidate) async throws -> Void) {
        self.run = run
    }

    /// Submits service-owned work without retaining a task for each queued item.
    func submit(_ candidates: [OfflineSnapshotWorkCandidate]) {
        guard !stopped else { return }
        for candidate in candidates { enqueue(candidate) }
        startPendingWork()
    }

    /// Joins current equivalent work. Cancelling this caller only unregisters its
    /// waiter, never cancels service-required work or reverses committed policy.
    func submitAndWait(_ candidate: OfflineSnapshotWorkCandidate) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !stopped, !Task.isCancelled else {
                    continuation.resume(throwing: Failure.cancelled)
                    return
                }
                enqueue(candidate, waiter: (waiterID, continuation))
                startPendingWork()
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        })
    }

    /// Removes queued work and cancels/joins affected active work, including cleanup.
    func invalidate(_ keys: Set<OfflineSnapshotKey>) async {
        let identities = Set(keys.map(Identity.init))
        let removed = pending.filter { identities.contains(Identity($0.candidate.key)) }
        pending.removeAll { identities.contains(Identity($0.candidate.key)) }
        for work in removed { finish(work, outcome: .failure(.cancelled)) }
        let tasks = revokeActive(identities)
        for task in tasks { await task.value }
        resumeIdleWaitersIfNeeded()
    }

    /// Cancels and joins current work but leaves admission open for later submissions.
    func invalidateAll() async {
        let removed = pending
        pending.removeAll()
        for work in removed { finish(work, outcome: .failure(.cancelled)) }
        let tasks = revokeActive(Set(active.keys))
        for task in tasks { await task.value }
        resumeIdleWaitersIfNeeded()
    }

    /// Observes the actual queue/active lifecycle. Cancellation only ends this wait.
    func waitUntilIdle() async {
        guard !pending.isEmpty || !active.isEmpty else { return }
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    idleWaiters[id] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelIdleWaiter(id) }
        })
    }

    /// Permanently closes submissions before cancelling and joining all owned work.
    func stop() async {
        stopped = true
        await invalidateAll()
    }

    private func enqueue(
        _ candidate: OfflineSnapshotWorkCandidate,
        waiter: (UUID, CheckedContinuation<Void, any Error>)? = nil
    ) {
        let identity = Identity(candidate.key)
        if let current = active[identity], current.revoked == nil,
           equivalent(current.work.candidate, candidate) {
            if let (id, continuation) = waiter { active[identity]?.work.waiters[id] = continuation }
            return
        }
        if let index = pending.firstIndex(where: { equivalent($0.candidate, candidate) }) {
            if let (id, continuation) = waiter { pending[index].waiters[id] = continuation }
            return
        }
        // A replacement owns a new work ID. Cancelled cleanup still occupies its
        // identity/slot until completion, so no duplicate preparation can start.
        if var current = active[identity], current.revoked == nil {
            current.revoked = .superseded
            active[identity] = current
            current.task.cancel()
        }
        if let index = pending.firstIndex(where: { Identity($0.candidate.key) == identity }) {
            let obsolete = pending.remove(at: index)
            finish(obsolete, outcome: .failure(.superseded))
        }
        var work = Work(candidate: candidate)
        if let (id, continuation) = waiter { work.waiters[id] = continuation }
        pending.append(work)
    }

    private func equivalent(_ lhs: OfflineSnapshotWorkCandidate, _ rhs: OfflineSnapshotWorkCandidate) -> Bool {
        guard lhs.key == rhs.key, lhs.shareID == rhs.shareID,
              lhs.metadataModifyTime == rhs.metadataModifyTime, lhs.itemType == rhs.itemType else { return false }
        switch (lhs.intent, rhs.intent) {
        case (.materialize(let left), .materialize(let right)),
             (.materialize(let left), .refresh(let right)),
             (.refresh(let left), .materialize(let right)),
             (.refresh(let left), .refresh(let right)),
             (.vaultMaterialize(let left), .vaultMaterialize(let right)):
            return left == right
        default:
            // Policy and selection UUIDs are different namespaces. The service
            // must join proven active ownership when promoting a vault item.
            return false
        }
    }

    private func startPendingWork() {
        while !stopped, active.count < 4,
              let index = pending.firstIndex(where: { active[Identity($0.candidate.key)] == nil }) {
            let work = pending.remove(at: index)
            let identity = Identity(work.candidate.key)
            let run = self.run
            let workID = work.id
            let candidate = work.candidate
            let task = Task {
                let outcome: Outcome
                do {
                    try Task.checkCancellation()
                    try await run(candidate)
                    // A successful committed callback is not rolled back by a
                    // late cancellation. Revocation only affects waiter outcomes.
                    outcome = .success
                } catch is CancellationError {
                    outcome = .failure(.cancelled)
                } catch let failure as Failure {
                    outcome = .failure(failure)
                } catch {
                    outcome = .failure(.unavailable)
                }
                complete(workID: workID, identity: identity, outcome: outcome)
            }
            // Task inherits this executor: store its handle before any yield.
            active[identity] = ActiveWork(work: work, task: task)
        }
        resumeIdleWaitersIfNeeded()
    }

    private func complete(workID: UUID, identity: Identity, outcome: Outcome) {
        guard let current = active[identity], current.work.id == workID else { return }
        active.removeValue(forKey: identity)
        finish(current.work, outcome: current.revoked.map(Outcome.failure) ?? outcome)
        startPendingWork()
    }

    private func revokeActive(_ identities: Set<Identity>) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        for identity in identities {
            guard var current = active[identity] else { continue }
            if current.revoked == nil { current.revoked = .cancelled }
            active[identity] = current
            current.task.cancel()
            tasks.append(current.task)
        }
        return tasks
    }

    private func cancelWaiter(_ id: UUID) {
        for identity in active.keys {
            if let continuation = active[identity]?.work.waiters.removeValue(forKey: id) {
                continuation.resume(throwing: Failure.cancelled)
                return
            }
        }
        for index in pending.indices {
            if let continuation = pending[index].waiters.removeValue(forKey: id) {
                continuation.resume(throwing: Failure.cancelled)
                return
            }
        }
    }

    private func finish(_ work: Work, outcome: Outcome) {
        for continuation in work.waiters.values {
            switch outcome {
            case .success: continuation.resume()
            case .failure(let failure): continuation.resume(throwing: failure)
            }
        }
    }

    private func cancelIdleWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard pending.isEmpty, active.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for continuation in waiters.values { continuation.resume() }
    }
}
