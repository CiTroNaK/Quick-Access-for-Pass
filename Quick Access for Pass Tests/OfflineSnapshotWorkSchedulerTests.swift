import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite(.timeLimit(.minutes(1)))
struct OfflineSnapshotWorkSchedulerTests {
    @Test func suspendedAdmissionFinishesWaiterAndReleasesSlot() async throws {
        let recorder = OfflineWorkRecorder()
        let denied = candidate("denied")
        let scheduler = OfflineSnapshotWorkScheduler { job in
            if job.key == denied.key { throw OfflineSnapshotWorkScheduler.Failure.selectionSuspended }
            try await recorder.run(job)
        }
        await #expect(throws: OfflineSnapshotWorkScheduler.Failure.selectionSuspended) {
            try await scheduler.submitAndWait(denied)
        }
        await scheduler.submit((0..<4).map { candidate("allowed-\($0)") })
        try await recorder.waitForStartedCount(4)
        #expect(await recorder.maximumActiveCount() == 4)
        await recorder.releaseAll()
        await scheduler.waitUntilIdle()
        await scheduler.stop()
    }

    @Test func overlappingSubmissionsShareFourSlotsAndDeduplicate() async throws {
        try await withScheduler { scheduler, recorder in
            let generation = UUID()
            let jobs = (0..<12).map { candidate("item-\($0)", generation: generation) }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<3 { group.addTask { await scheduler.submit(jobs) } }
            }
            try await recorder.waitForStartedCount(4)
            #expect(await recorder.maximumActiveCount() == 4)
            #expect(await recorder.startedCount() == 4)
            await recorder.releaseAll()
            await scheduler.waitUntilIdle()
            #expect(await recorder.completedCount() == 12)
            #expect(await recorder.maximumCallsPerKey() == 1)
        }
    }

    @Test func sameItemWaitersJoinOwnedWork() async throws {
        try await withScheduler { scheduler, recorder in
            let job = candidate("item")
            let first = Task { try await scheduler.submitAndWait(job) }
            do {
                try await recorder.waitForStartedCount(1)
                try await joinAndRelease(job, scheduler: scheduler, recorder: recorder)
                try await first.value
                #expect(await recorder.calls(for: job.key) == 1)
            } catch {
                first.cancel()
                await recorder.releaseAll()
                _ = await first.result
                throw error
            }
        }
    }

    @Test func cancellingOneWaiterDoesNotCancelSharedWork() async throws {
        try await withScheduler { scheduler, recorder in
            let job = candidate("item")
            let first = Task { try await scheduler.submitAndWait(job) }
            do {
                try await recorder.waitForStartedCount(1)
                first.cancel()
                await #expect(throws: OfflineSnapshotWorkScheduler.Failure.cancelled) { try await first.value }
                #expect(await recorder.activeCount() == 1)
                try await joinAndRelease(job, scheduler: scheduler, recorder: recorder)
                #expect(await recorder.completedCount() == 1)
                #expect(await recorder.calls(for: job.key) == 1)
            } catch {
                first.cancel()
                await recorder.releaseAll()
                _ = await first.result
                throw error
            }
        }
    }

    @Test func cancellationRacingWaiterRegistrationDoesNotAdmitWork() async throws {
        try await withScheduler { scheduler, recorder in
            let gate = OfflineTestGate()
            let waiter = Task {
                try? await gate.wait()
                try await scheduler.submitAndWait(candidate("item"))
            }
            waiter.cancel()
            await gate.open()
            await #expect(throws: OfflineSnapshotWorkScheduler.Failure.cancelled) { try await waiter.value }
            #expect(await recorder.startedCount() == 0)
        }
    }

    @Test func invalidatingQueuedWorkNeverStartsItAndActiveWorkIsJoined() async throws {
        let recorder = OfflineWorkRecorder(holdCancelledCleanup: true)
        try await withScheduler(recorder: recorder) { scheduler, recorder in
            let generation = UUID()
            let jobs = (0..<6).map { candidate("item-\($0)", generation: generation) }
            await scheduler.submit(jobs)
            try await recorder.waitForStartedCount(4)
            await scheduler.invalidate([jobs[4].key])
            let invalidation = Task { await scheduler.invalidate([jobs[0].key]) }
            do {
                try await recorder.waitForCancellationCount(1)
                #expect(await recorder.activeCount() == 4)
                #expect(await recorder.calls(for: jobs[4].key) == 0)
                await recorder.releaseAll()
                await invalidation.value
                await scheduler.waitUntilIdle()
                #expect(await recorder.calls(for: jobs[4].key) == 0)
                #expect(await recorder.completedCount() == 4)
            } catch {
                await recorder.releaseAll()
                await invalidation.value
                throw error
            }
        }
    }

    @Test func newerPolicyGenerationWaitsForRevokedIdentityCleanup() async throws {
        let recorder = OfflineWorkRecorder(holdCancelledCleanup: true)
        try await withScheduler(recorder: recorder) { scheduler, recorder in
            let old = candidate("item", intent: .vaultMaterialize(policyGeneration: UUID()))
            let new = candidate("item", intent: .vaultMaterialize(policyGeneration: UUID()))
            await scheduler.submit([old])
            try await recorder.waitForStartedCount(1)
            let invalidation = Task { await scheduler.invalidate([old.key]) }
            do {
                try await recorder.waitForCancellationCount(1)
                await scheduler.submit([new, new])
                #expect(await recorder.startedCount() == 1)
                await recorder.releaseCancelledCleanup()
                await invalidation.value
                try await recorder.waitForStartedCount(2)
                #expect(await recorder.maximumActiveCount() == 1)
                await recorder.releaseAll()
                await scheduler.waitUntilIdle()
                #expect(await recorder.startedCandidates() == [old, new])
                #expect(await recorder.completedCount() == 1)
            } catch {
                await recorder.releaseAll()
                await invalidation.value
                throw error
            }
        }
    }

    @Test func newerMetadataSupersedesRatherThanJoiningObsoleteResult() async throws {
        let recorder = OfflineWorkRecorder(holdCancelledCleanup: true)
        try await withScheduler(recorder: recorder) { scheduler, recorder in
            let generation = UUID()
            let old = candidate("item", generation: generation)
            let new = candidate("item", generation: generation, modifyTime: 3)
            let waiter = Task { try await scheduler.submitAndWait(old) }
            do {
                try await recorder.waitForStartedCount(1)
                await scheduler.submit([new, new])
                try await recorder.waitForCancellationCount(1)
                #expect(await recorder.startedCount() == 1)
                await recorder.releaseCancelledCleanup()
                await #expect(throws: OfflineSnapshotWorkScheduler.Failure.superseded) { try await waiter.value }
                try await recorder.waitForStartedCount(2)
                #expect(await recorder.maximumActiveCount() == 1)
                await recorder.releaseAll()
                await scheduler.waitUntilIdle()
                #expect(await recorder.startedCandidates() == [old, new])
            } catch {
                waiter.cancel()
                await recorder.releaseAll()
                _ = await waiter.result
                throw error
            }
        }
    }

    @Test(arguments: ["share", "type", "selection", "policy-namespace", "schema"])
    func changedWorkIdentityDoesNotJoin(dimension: String) async throws {
        try await withScheduler { scheduler, recorder in
            let generation = UUID()
            let old = candidate("item", generation: generation)
            let new: OfflineSnapshotWorkCandidate
            switch dimension {
            case "share": new = candidate("item", generation: generation, shareID: "new-share")
            case "type": new = candidate("item", generation: generation, itemType: .note)
            case "selection": new = candidate("item", generation: UUID())
            case "policy-namespace": new = candidate("item", intent: .vaultMaterialize(policyGeneration: generation))
            default: new = candidate("item", generation: generation, schemaVersion: 2)
            }
            await scheduler.submit([old])
            try await recorder.waitForStartedCount(1)
            await scheduler.submit([new])
            try await recorder.waitForStartedCount(2)
            await recorder.releaseAll()
            await scheduler.waitUntilIdle()
            #expect(await recorder.startedCandidates() == [old, new])
            #expect(await recorder.maximumActiveCount() == 1)
        }
    }

    @Test func materializationAndRefreshJoinSameSelectionGeneration() async throws {
        try await withScheduler { scheduler, recorder in
            let generation = UUID()
            let preparation = candidate("item", generation: generation)
            let refresh = candidate("item", intent: .refresh(selectionGeneration: generation))
            await scheduler.submit([preparation])
            try await recorder.waitForStartedCount(1)
            try await joinAndRelease(refresh, scheduler: scheduler, recorder: recorder)
            #expect(await recorder.calls(for: preparation.key) == 1)
        }
    }

    @Test func queuedReplacementCoalescesAndOnlyRunsLatestMetadata() async throws {
        try await withScheduler { scheduler, recorder in
            let generation = UUID()
            let blockers = (0..<4).map { candidate("blocker-\($0)", generation: generation) }
            let old = candidate("queued", generation: generation)
            let new = candidate("queued", generation: generation, modifyTime: 3)
            await scheduler.submit(blockers + [old])
            try await recorder.waitForStartedCount(4)
            await scheduler.submit([new, new])
            await recorder.releaseAll()
            await scheduler.waitUntilIdle()
            #expect(await recorder.calls(for: old.key) == 1)
            #expect(await recorder.startedCandidates().contains(old) == false)
            #expect(await recorder.startedCandidates().contains(new))
        }
    }

    @Test func queuedWaiterIsFinishedOnInvalidation() async throws {
        try await withScheduler { scheduler, recorder in
            let blockers = (0..<4).map { candidate("blocker-\($0)") }
            await scheduler.submit(blockers)
            try await recorder.waitForStartedCount(4)
            let queued = candidate("queued")
            await #expect(throws: OfflineSnapshotWorkScheduler.Failure.cancelled) {
                try await waitForQueuedExit(queued, replacement: nil, scheduler: scheduler)
            }
            #expect(await recorder.calls(for: queued.key) == 0)
            await recorder.releaseAll()
            await scheduler.waitUntilIdle()
            #expect(await recorder.completedCount() == 4)
        }
    }

    @Test func queuedWaiterIsFinishedWhenSuperseded() async throws {
        try await withScheduler { scheduler, recorder in
            await scheduler.submit((0..<4).map { candidate("blocker-\($0)") })
            try await recorder.waitForStartedCount(4)
            let generation = UUID()
            let old = candidate("queued", generation: generation)
            let new = candidate("queued", generation: generation, modifyTime: 3)
            await #expect(throws: OfflineSnapshotWorkScheduler.Failure.superseded) {
                try await waitForQueuedExit(old, replacement: new, scheduler: scheduler)
            }
            await recorder.releaseAll()
            await scheduler.waitUntilIdle()
            #expect(await recorder.startedCandidates().contains(old) == false)
            #expect(await recorder.startedCandidates().contains(new))
            #expect(await recorder.completedCount() == 5)
        }
    }

    @Test func activeWaiterIsFinishedOnInvalidation() async throws {
        try await withScheduler { scheduler, recorder in
            let job = candidate("item")
            let waiter = Task { try await scheduler.submitAndWait(job) }
            do {
                try await recorder.waitForStartedCount(1)
                await scheduler.invalidate([job.key])
                await #expect(throws: OfflineSnapshotWorkScheduler.Failure.cancelled) { try await waiter.value }
                #expect(await recorder.activeCount() == 0)
            } catch {
                waiter.cancel()
                await recorder.releaseAll()
                _ = await waiter.result
                throw error
            }
        }
    }

    @Test func cancellingIdleWaitDoesNotStopOwnedWork() async throws {
        try await withScheduler { scheduler, recorder in
            await scheduler.submit([candidate("item")])
            try await recorder.waitForStartedCount(1)
            let wait = Task { await scheduler.waitUntilIdle() }
            wait.cancel()
            await wait.value
            #expect(await recorder.activeCount() == 1)
            await recorder.releaseAll()
            await scheduler.waitUntilIdle()
            #expect(await recorder.completedCount() == 1)
        }
    }

    @Test func invalidateAllJoinsCleanupButAllowsLaterSubmission() async throws {
        try await withScheduler { scheduler, recorder in
            let job = candidate("item")
            await scheduler.submit([job])
            try await recorder.waitForStartedCount(1)
            await scheduler.invalidateAll()
            #expect(await recorder.activeCount() == 0)
            await recorder.releaseAll()
            try await scheduler.submitAndWait(job)
            await scheduler.waitUntilIdle()
            #expect(await recorder.calls(for: job.key) == 2)
        }
    }

    @Test func stopJoinsAndPermanentlyRejectsSubmissions() async throws {
        try await withScheduler { scheduler, recorder in
            await scheduler.submit((0..<6).map { candidate("item-\($0)") })
            try await recorder.waitForStartedCount(4)
            await scheduler.stop()
            #expect(await recorder.activeCount() == 0)
            await scheduler.submit([candidate("later")])
            await #expect(throws: OfflineSnapshotWorkScheduler.Failure.cancelled) {
                try await scheduler.submitAndWait(candidate("later"))
            }
            await scheduler.waitUntilIdle()
            #expect(await recorder.startedCount() == 4)
        }
    }

    @Test func singleJobFailureIsSanitizedAndDoesNotCancelSiblings() async throws {
        let failed = candidate("failed")
        let recorder = OfflineWorkRecorder(failingKeys: [failed.key])
        try await withScheduler(recorder: recorder) { scheduler, recorder in
            await scheduler.submit([candidate("sibling")])
            await #expect(throws: OfflineSnapshotWorkScheduler.Failure.unavailable) {
                try await joinAndRelease(failed, scheduler: scheduler, recorder: recorder)
            }
            await scheduler.waitUntilIdle()
            #expect(await recorder.completedCount() == 1)
            #expect(await recorder.startedCount() == 2)
        }
    }

    @Test func queuedWorkRechecksAvailabilityInInjectedRun() async throws {
        let availability = OfflineWorkAvailability()
        let recorder = OfflineWorkRecorder()
        let scheduler = OfflineSnapshotWorkScheduler(run: { job in
            if job.key.itemId == "target" {
                if await availability.shouldSkipPreparation() { return }
                await availability.commitAfterRelease()
            }
            try await recorder.run(job)
        })
        do {
            let old = candidate("target", intent: .vaultMaterialize(policyGeneration: UUID()))
            let replacement = candidate("target")
            await scheduler.submit([old])
            try await availability.waitUntilEntered()
            // The old operation may commit despite late cancellation. Replacement
            // must reach run only after cleanup, where it can recheck committed state.
            await scheduler.submit([replacement])
            await availability.release()
            await recorder.releaseAll()
            await scheduler.waitUntilIdle()
            #expect(await availability.isCommitted())
            #expect(await availability.attemptCount() == 2)
            #expect(await recorder.calls(for: old.key) == 1)
        } catch {
            await availability.release()
            await recorder.releaseAll()
            await scheduler.stop()
            await recorder.drain()
            throw error
        }
        await scheduler.stop()
        await recorder.drain()
    }
}

nonisolated private func candidate(
    _ itemID: String, generation: UUID = UUID(), modifyTime: TimeInterval = 2,
    shareID: String = "share", itemType: ItemType = .login, schemaVersion: UInt8 = 1,
    intent: OfflineSnapshotWorkIntent? = nil
) -> OfflineSnapshotWorkCandidate {
    OfflineSnapshotWorkCandidate(
        key: OfflineSnapshotKey(vaultId: "vault", itemId: itemID, schemaVersion: schemaVersion),
        shareID: shareID, metadataModifyTime: Date(timeIntervalSince1970: modifyTime),
        itemType: itemType, intent: intent ?? .materialize(selectionGeneration: generation)
    )
}

/// The releaser inherits the scheduler executor. It cannot open work before
/// submitAndWait has synchronously registered its waiter and suspended.
private func joinAndRelease(
    _ job: OfflineSnapshotWorkCandidate, scheduler: isolated OfflineSnapshotWorkScheduler,
    recorder: OfflineWorkRecorder
) async throws {
    let release = Task { await recorder.releaseAll() }
    do {
        try await scheduler.submitAndWait(job)
        await release.value
    } catch {
        await release.value
        throw error
    }
}

/// Like joinAndRelease, the mutation cannot run until the queued waiter is registered.
private func waitForQueuedExit(
    _ job: OfflineSnapshotWorkCandidate, replacement: OfflineSnapshotWorkCandidate?,
    scheduler: isolated OfflineSnapshotWorkScheduler
) async throws {
    let mutation = Task {
        if let replacement { scheduler.submit([replacement]) }
        else { await scheduler.invalidate([job.key]) }
    }
    do {
        try await scheduler.submitAndWait(job)
        await mutation.value
    } catch {
        await mutation.value
        throw error
    }
}

nonisolated private func withScheduler(
    recorder: OfflineWorkRecorder = OfflineWorkRecorder(),
    body: @Sendable (OfflineSnapshotWorkScheduler, OfflineWorkRecorder) async throws -> Void
) async throws {
    let scheduler = OfflineSnapshotWorkScheduler(run: { try await recorder.run($0) })
    do {
        try await body(scheduler, recorder)
    } catch {
        await recorder.releaseAll()
        await scheduler.stop()
        await recorder.drain()
        throw error
    }
    await recorder.releaseAll()
    await scheduler.stop()
    await recorder.drain()
}

private actor OfflineWorkAvailability {
    private var committed = false
    private var attempts = 0
    private var released = false
    private let entry = OfflineTestGate()
    private var continuation: CheckedContinuation<Void, Never>?

    func isCommitted() -> Bool { committed }
    func attemptCount() -> Int { attempts }
    func shouldSkipPreparation() -> Bool {
        attempts += 1
        return committed
    }
    func waitUntilEntered() async throws { try await entry.wait() }

    func commitAfterRelease() async {
        await entry.open()
        if !released { await withCheckedContinuation { continuation = $0 } }
        committed = true
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
