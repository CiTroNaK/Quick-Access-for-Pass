import Foundation
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill request registry")
struct AutoFillRequestRegistryTests {
    private let requestID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let descriptorID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let connectionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    @Test("begin computes one monotonic deadline capped at 30 seconds and rejects replay")
    func monotonicDeadlineAndReplay() async throws {
        let clock = FakeMonotonicClock(now: 10)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)

        let request = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password,
            deadline: UInt64.max
        )
        #expect(request.deadline == 30_000_000_010)
        clock.set(10_000_000_010)
        #expect(try await registry.remainingTime(for: requestID) == .seconds(20))

        #expect(try await registry.cancel(requestID: requestID, connectionID: nil))
        await #expect(throws: AutoFillRequestRegistry.Error.replayedRequest) {
            try await registry.begin(
                requestID: requestID,
                descriptorID: descriptorID,
                kind: .password
            )
        }
    }

    @Test("atomic bind and claim consumes only a verified live handle")
    func atomicBindAndClaim() async throws {
        let clock = FakeMonotonicClock(now: 100)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        let handle = UUID()
        let connection = UUID()
        try await registry.registerWake(handle: handle, deadline: 200)

        try await registry.bindVerifiedConnection(
            connection,
            peer: verifiedPeer(),
            wakeHandle: handle,
            requestDeadline: 200
        )

        #expect(await registry.claimedWakeDeadline(connectionID: connection) == 200)
        #expect(await registry.counts().wakeHandles == 0)
    }

    @Test("failed atomic claim leaves the live handle available")
    func failedAtomicClaimPreservesHandle() async throws {
        let clock = FakeMonotonicClock(now: 100)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        let handle = UUID()
        try await registry.registerWake(handle: handle, deadline: 200)

        await #expect(throws: AutoFillRequestRegistry.Error.invalidWakeClaim) {
            try await registry.bindVerifiedConnection(
                UUID(),
                peer: verifiedPeer(),
                wakeHandle: handle,
                requestDeadline: 201
            )
        }

        let connection = UUID()
        try await registry.bindVerifiedConnection(
            connection,
            peer: verifiedPeer(),
            wakeHandle: handle,
            requestDeadline: 200
        )
        #expect(await registry.claimedWakeDeadline(connectionID: connection) == 200)
    }

    @Test("wake and replay records expire without another registry operation")
    func scheduledWakeExpiry() async throws {
        let clock = FakeMonotonicClock(now: 100)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        let liveHandle = UUID()
        let usedHandle = UUID()
        try await registry.registerWake(handle: liveHandle, deadline: 200)
        try await registry.registerWake(handle: usedHandle, deadline: 300)
        try await registry.bindVerifiedConnection(
            UUID(),
            peer: verifiedPeer(),
            wakeHandle: usedHandle,
            requestDeadline: 300
        )

        clock.set(200)
        await scheduler.fireAll()
        #expect(await registry.counts().wakeHandles == 0)

        clock.set(300)
        await scheduler.fireAll()
        try await registry.registerWake(handle: usedHandle, deadline: 400)
    }

    @Test("request terminal operations reject a cross-connection attempt")
    func crossConnectionTerminalAttempt() async throws {
        let registry = AutoFillRequestRegistry()
        let otherConnectionID = UUID()
        try await bindVerified(connectionID, to: registry)
        try await bindVerified(otherConnectionID, to: registry)
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password
        )
        try await registry.bindConnection(requestID: requestID, connectionID: connectionID)

        #expect(try await registry.complete(requestID: requestID, connectionID: otherConnectionID) == false)
        #expect(try await registry.complete(requestID: requestID, connectionID: connectionID))
        #expect(await registry.terminalResult(for: requestID) == .completed)
    }

    @Test("cancellation wins exactly once from every nonterminal state", arguments: [
        AutoFillRequestState.created,
        .launching,
        .connecting,
        .awaitingUnlock,
        .resolving
    ])
    func cancellationFromEveryState(state: AutoFillRequestState) async throws {
        let registry = AutoFillRequestRegistry()
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password
        )
        try await move(requestID: requestID, to: state, in: registry)

        #expect(try await registry.cancel(requestID: requestID, connectionID: nil))
        #expect(try await registry.cancel(requestID: requestID, connectionID: nil) == false)
        #expect(await registry.terminalResult(for: requestID) == .cancelled)
    }

    @Test("timeout uses the original deadline in every nonterminal state", arguments: [
        AutoFillRequestState.created,
        .launching,
        .connecting,
        .awaitingUnlock,
        .resolving
    ])
    func timeoutFromEveryState(state: AutoFillRequestState) async throws {
        let clock = FakeMonotonicClock(now: 1_000)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .oneTimeCode,
            deadline: 2_000
        )
        try await move(requestID: requestID, to: state, in: registry)

        clock.set(2_000)
        let timedOut = await registry.expireTimedOutRequests()
        #expect(timedOut == [requestID])
        #expect(await registry.terminalResult(for: requestID) == .timedOut)
    }

    @Test("late completion at the exact deadline records timeout and resumes its waiter once")
    func lateCompletionAtDeadlineTimesOut() async throws {
        let clock = FakeMonotonicClock(now: 100)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password,
            deadline: 200
        )
        let waiter = Task { try await registry.waitForTerminal(requestID: requestID) }

        clock.set(200)
        #expect(try await registry.complete(requestID: requestID, connectionID: nil) == false)
        #expect(try await waiter.value == .timedOut)
        #expect(await registry.terminalResult(for: requestID) == .timedOut)
        #expect(try await registry.cancel(requestID: requestID, connectionID: nil) == false)
    }

    @Test("an idle waiter times out when the controlled scheduler reaches its deadline")
    func idleWaiterTimesOutOnControlledSchedule() async throws {
        let clock = FakeMonotonicClock(now: 1_000)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password,
            deadline: 2_000
        )
        let waiter = Task { try await registry.waitForTerminal(requestID: requestID) }

        clock.set(2_000)
        await scheduler.fireAll()

        #expect(try await waiter.value == .timedOut)
        #expect(await registry.terminalResult(for: requestID) == .timedOut)
    }

    @Test("an idle waiter times out under the production monotonic scheduler", .timeLimit(.minutes(1)))
    func idleWaiterTimesOutInRealBoundedDuration() async throws {
        let registry = AutoFillRequestRegistry()
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password,
            deadline: deadline
        )

        #expect(try await registry.waitForTerminal(requestID: requestID) == .timedOut)
    }

    @Test("concurrent completion, cancellation, and scheduled timeout finish exactly once")
    func concurrentTerminalAndTimeoutRace() async throws {
        let clock = FakeMonotonicClock(now: 100)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password,
            deadline: 200
        )
        let waiter = Task { try await registry.waitForTerminal(requestID: requestID) }
        clock.set(200)

        let requestedTerminals = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await registry.complete(requestID: self.requestID, connectionID: nil) }
            group.addTask { try await registry.cancel(requestID: self.requestID, connectionID: nil) }
            group.addTask {
                await scheduler.fireAll()
                return false
            }
            var results: [Bool] = []
            for try await result in group { results.append(result) }
            return results
        }

        #expect(requestedTerminals.allSatisfy { $0 == false })
        #expect(try await waiter.value == .timedOut)
        #expect(await registry.terminalResult(for: requestID) == .timedOut)
    }

    @Test("live request and wake tombstones fail closed at capacity instead of permitting replay")
    func liveTombstonesRemainBoundedAndRejectReplay() async throws {
        let clock = FakeMonotonicClock(now: 100)
        let scheduler = ControlledTimeoutScheduler()
        let requestRegistry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        let firstRequestID = UUID()
        for index in 0..<256 {
            let id = index == 0 ? firstRequestID : UUID()
            _ = try await requestRegistry.begin(
                requestID: id,
                descriptorID: descriptorID,
                kind: .password,
                deadline: 30_000_000_100
            )
            #expect(try await requestRegistry.complete(requestID: id, connectionID: nil))
        }
        await scheduler.fireAll()
        await #expect(throws: AutoFillRequestRegistry.Error.capacityExceeded) {
            try await requestRegistry.begin(
                requestID: UUID(),
                descriptorID: descriptorID,
                kind: .password,
                deadline: 30_000_000_100
            )
        }
        await #expect(throws: AutoFillRequestRegistry.Error.replayedRequest) {
            try await requestRegistry.begin(
                requestID: firstRequestID,
                descriptorID: descriptorID,
                kind: .password,
                deadline: 30_000_000_100
            )
        }

        let wakeRegistry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        let firstHandle = UUID()
        for index in 0..<256 {
            let handle = index == 0 ? firstHandle : UUID()
            let connection = UUID()
            try await wakeRegistry.registerWake(handle: handle, deadline: 30_000_000_100)
            try await wakeRegistry.bindVerifiedConnection(
                connection,
                peer: verifiedPeer(),
                wakeHandle: handle,
                requestDeadline: 30_000_000_100
            )
            await wakeRegistry.removeConnection(connection)
        }
        await #expect(throws: AutoFillRequestRegistry.Error.capacityExceeded) {
            try await wakeRegistry.registerWake(handle: UUID(), deadline: 30_000_000_100)
        }
        await #expect(throws: AutoFillRequestRegistry.Error.replayedWake) {
            try await wakeRegistry.registerWake(handle: firstHandle, deadline: 30_000_000_100)
        }
    }

    @Test("two simultaneous terminal attempts produce exactly one winner")
    func simultaneousTerminalAttempts() async throws {
        let registry = AutoFillRequestRegistry()
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password
        )

        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await registry.complete(requestID: requestID, connectionID: nil)
            }
            group.addTask {
                try await registry.cancel(requestID: requestID, connectionID: nil)
            }
            var values: [Bool] = []
            for try await value in group { values.append(value) }
            return values
        }

        #expect(results.filter { $0 }.count == 1)
        #expect(results.filter { $0 == false }.count == 1)
    }

    @Test("terminal result resumes exactly once whether completion races before or after waiter registration")
    func continuationRaceIsExactlyOnce() async throws {
        let registry = AutoFillRequestRegistry()
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password
        )
        #expect(try await registry.complete(requestID: requestID, connectionID: nil))
        #expect(try await registry.waitForTerminal(requestID: requestID) == .completed)

        let secondID = UUID()
        _ = try await registry.begin(
            requestID: secondID,
            descriptorID: descriptorID,
            kind: .password
        )
        let waiter = Task { try await registry.waitForTerminal(requestID: secondID) }
        await Task.yield()
        #expect(try await registry.fail(
            requestID: secondID,
            connectionID: nil,
            failure: .resolutionFailed
        ))
        #expect(try await waiter.value == .failed(.resolutionFailed))
        #expect(try await registry.complete(requestID: secondID, connectionID: nil) == false)
    }

    @Test("cancelling a waiting task reaches the same exactly-once terminal path")
    func waitingTaskCancellationIsExactlyOnce() async throws {
        let registry = AutoFillRequestRegistry()
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password
        )
        let waiter = Task { try await registry.waitForTerminal(requestID: requestID) }
        waiter.cancel()

        #expect(try await waiter.value == .cancelled)
        #expect(try await registry.complete(requestID: requestID, connectionID: nil) == false)
    }

    private func bindVerified(_ id: UUID, to registry: AutoFillRequestRegistry) async throws {
        try await registry.bindConnection(
            id,
            peer: VerifiedAutoFillPeer(fileDescriptor: 9, identifier: "fake.peer", teamID: "FAKETEAM")
        )
    }

    private func move(
        requestID: UUID,
        to target: AutoFillRequestState,
        in registry: AutoFillRequestRegistry
    ) async throws {
        switch target {
        case .created:
            return
        case .launching:
            try await registry.transition(requestID: requestID, to: .launching)
        case .connecting:
            try await registry.transition(requestID: requestID, to: .connecting)
        case .awaitingUnlock:
            try await registry.transition(requestID: requestID, to: .connecting)
            try await registry.transition(requestID: requestID, to: .awaitingUnlock)
        case .resolving:
            try await registry.transition(requestID: requestID, to: .connecting)
            try await registry.transition(requestID: requestID, to: .resolving)
        case .completed, .cancelled, .timedOut, .failed:
            Issue.record("Terminal states are not test inputs")
        }
    }
}

extension AutoFillRequestRegistryTests {
    @Test("a valid completion racing expiry produces one terminal result and resumes its waiter once")
    func completionRacingExpiryResumesWaiterOnce() async throws {
        let clock = FakeMonotonicClock(now: 100)
        let scheduler = ControlledTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        _ = try await registry.begin(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: .password,
            deadline: 200
        )
        let waiter = Task { try await registry.waitForTerminal(requestID: requestID) }
        await Task.yield()

        let completionWon = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await registry.complete(requestID: self.requestID, connectionID: nil)
            }
            group.addTask {
                clock.set(200)
                await scheduler.fireAll()
                return false
            }
            var winner = false
            for try await result in group {
                winner = winner || result
            }
            return winner
        }

        let terminal = await registry.terminalResult(for: requestID)
        #expect(terminal == .completed || terminal == .timedOut)
        #expect(try await waiter.value == terminal)
        #expect(completionWon == (terminal == .completed))
        #expect(try await registry.cancel(requestID: requestID, connectionID: nil) == false)
    }

    @Test("pending requests, wake handles, verified connections, and replay history are bounded")
    func stateIsBounded() async throws {
        let registry = AutoFillRequestRegistry(limits: .init(
            pendingRequests: 1,
            wakeHandles: 1,
            connections: 1,
            replayHistory: 1
        ))
        _ = try await registry.begin(requestID: requestID, descriptorID: descriptorID, kind: .password)
        await #expect(throws: AutoFillRequestRegistry.Error.capacityExceeded) {
            try await registry.begin(requestID: UUID(), descriptorID: descriptorID, kind: .password)
        }

        try await registry.registerWake(handle: UUID(), deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        await #expect(throws: AutoFillRequestRegistry.Error.capacityExceeded) {
            try await registry.registerWake(handle: UUID(), deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        }

        try await bindVerified(connectionID, to: registry)
        await #expect(throws: AutoFillRequestRegistry.Error.capacityExceeded) {
            try await bindVerified(UUID(), to: registry)
        }
    }
}

private func verifiedPeer() -> VerifiedAutoFillPeer {
    VerifiedAutoFillPeer(fileDescriptor: 9, identifier: "fake.peer", teamID: "FAKETEAM")
}

private final class FakeMonotonicClock: Sendable {
    private let storage: Mutex<UInt64>

    init(now: UInt64) {
        storage = Mutex(now)
    }

    func read() -> UInt64 {
        storage.withLock { $0 }
    }

    func set(_ value: UInt64) {
        storage.withLock { $0 = value }
    }
}

private final class ControlledTimeoutScheduler: Sendable {
    private struct Scheduled: Sendable {
        let continuation: AsyncStream<Void>.Continuation
        let task: Task<Void, Never>
    }

    private let storage = Mutex<[UUID: Scheduled]>([:])

    func schedule(
        after _: Duration,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream {
                guard Task.isCancelled == false else { return }
                await operation()
                return
            }
        }
        storage.withLock { $0[id] = Scheduled(continuation: continuation, task: task) }
        return task
    }

    func fireAll() async {
        let scheduled = storage.withLock { state in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        for item in scheduled {
            item.continuation.yield()
            item.continuation.finish()
        }
        for item in scheduled {
            await item.task.value
        }
    }
}
