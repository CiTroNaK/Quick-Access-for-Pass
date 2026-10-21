import Foundation

actor AutoFillRequestRegistry {
    private var state = AutoFillRequestRegistryState()

    private static let maximumLifetimeNanoseconds: UInt64 = 30_000_000_000

    private let limits: Limits
    private let now: @Sendable () -> UInt64
    private let scheduleTimeout: @Sendable (
        Duration,
        @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>
    init(
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        scheduleTimeout: @escaping @Sendable (
            Duration,
            @escaping @Sendable () async -> Void
        ) -> Task<Void, Never> = AutoFillRequestRegistry.defaultScheduleTimeout
    ) {
        self.limits = limits
        self.now = now
        self.scheduleTimeout = scheduleTimeout
    }

    @discardableResult
    func begin(
        requestID: UUID,
        descriptorID: UUID,
        kind: AutoFillValueKind,
        deadline requestedDeadline: UInt64? = nil
    ) throws -> AutoFillRegisteredRequest {
        let current = now()
        expireTimedOutRequests(at: current)
        pruneTerminalEntries(at: current)
        guard state.requests[requestID] == nil, state.terminalEntries[requestID] == nil else {
            throw Error.replayedRequest
        }
        guard state.requests.count < limits.pendingRequests,
              state.requests.count + state.terminalEntries.count < limits.replayHistory else {
            throw Error.capacityExceeded
        }

        let maximumDeadline = AutoFillRequestRegistryState.addingClamped(Self.maximumLifetimeNanoseconds, to: current)
        let deadline = min(requestedDeadline ?? maximumDeadline, maximumDeadline)
        guard deadline > current else { throw Error.deadlineExpired }
        let request = AutoFillRegisteredRequest(
            requestID: requestID,
            descriptorID: descriptorID,
            kind: kind,
            deadline: deadline
        )
        state.requests[requestID] = AutoFillRequestRegistryState.Entry(
            request: request,
            state: .created,
            connectionID: nil,
            continuation: nil,
            timeoutTask: nil
        )
        armTimeout(for: requestID, deadline: deadline, current: current)
        return request
    }

    func registerWake(handle: UUID, deadline requestedDeadline: UInt64) throws {
        let current = now()
        expireWakeHandles(at: current)
        pruneUsedWakeHandles(at: current)
        guard state.wakeHandles[handle] == nil, state.usedWakeHandles[handle] == nil else {
            throw Error.replayedWake
        }
        guard state.wakeHandles.count < limits.wakeHandles,
              state.wakeHandles.count + state.usedWakeHandles.count < limits.replayHistory else {
            throw Error.capacityExceeded
        }
        let maximumDeadline = AutoFillRequestRegistryState.addingClamped(Self.maximumLifetimeNanoseconds, to: current)
        let deadline = min(requestedDeadline, maximumDeadline)
        guard deadline > current else { throw Error.deadlineExpired }
        state.wakeHandles[handle] = AutoFillRequestRegistryState.WakeEntry(deadline: deadline)
        armLiveWakeExpiry(for: handle, deadline: deadline, current: current)
    }

    /// Records a connection only after `AutoFillPeerVerifier` produced its proof.
    /// Possession of a wake handle alone never reaches this method.
    func bindConnection(_ connectionID: UUID, peer: VerifiedAutoFillPeer) throws {
        if state.verifiedConnections[connectionID] != nil {
            throw Error.connectionAlreadyBound
        }
        guard state.verifiedConnections.count < limits.connections else {
            throw Error.capacityExceeded
        }
        state.verifiedConnections[connectionID] = peer
    }

    /// Atomically consumes a live handle only when the connection has already
    /// been bound to a verified peer. An unverified mismatch leaves it usable.
    func claimWake(handle: UUID, connectionID: UUID) -> Bool {
        let current = now()
        expireWakeHandles(at: current)
        guard state.verifiedConnections[connectionID] != nil,
              let wake = state.wakeHandles[handle],
              wake.deadline > current,
              state.claimedWakeDeadlines[connectionID] == nil else {
            return false
        }
        cancelLiveWakeExpiry(for: handle)
        state.wakeHandles.removeValue(forKey: handle)
        state.usedWakeHandles[handle] = wake.deadline
        state.claimedWakeDeadlines[connectionID] = wake.deadline
        armUsedWakeExpiry(for: handle, deadline: wake.deadline, current: current)
        return true
    }

    func claimedWakeDeadline(connectionID: UUID) -> UInt64? {
        guard state.verifiedConnections[connectionID] != nil else { return nil }
        return state.claimedWakeDeadlines[connectionID]
    }

    /// Atomically records a verified connection and optionally consumes its live wake handle.
    func bindVerifiedConnection(
        _ connectionID: UUID,
        peer: VerifiedAutoFillPeer,
        wakeHandle: UUID?,
        requestDeadline: UInt64
    ) throws {
        let current = now()
        expireWakeHandles(at: current)
        pruneUsedWakeHandles(at: current)
        guard state.verifiedConnections[connectionID] == nil else {
            throw Error.connectionAlreadyBound
        }
        guard state.verifiedConnections.count < limits.connections else {
            throw Error.capacityExceeded
        }

        let wake = try wakeHandle.map { handle in
            guard let live = state.wakeHandles[handle],
                  live.deadline > current,
                  requestDeadline <= live.deadline else {
                throw Error.invalidWakeClaim
            }
            return (handle, live)
        }

        state.verifiedConnections[connectionID] = peer
        if let (handle, live) = wake {
            cancelLiveWakeExpiry(for: handle)
            state.wakeHandles.removeValue(forKey: handle)
            state.usedWakeHandles[handle] = live.deadline
            state.claimedWakeDeadlines[connectionID] = live.deadline
            armUsedWakeExpiry(for: handle, deadline: live.deadline, current: current)
        }
    }

    /// Binds a request to the verified socket connection that is allowed to
    /// drive transitions and terminal cleanup for that request.
    func bindConnection(requestID: UUID, connectionID: UUID) throws {
        guard state.verifiedConnections[connectionID] != nil else {
            throw Error.unverifiedConnection
        }
        guard var entry = state.requests[requestID] else { throw Error.unknownRequest }
        guard entry.connectionID == nil else { throw Error.connectionAlreadyBound }
        entry.connectionID = connectionID
        state.requests[requestID] = entry
    }

    func removeConnection(_ connectionID: UUID) {
        state.verifiedConnections.removeValue(forKey: connectionID)
        state.claimedWakeDeadlines.removeValue(forKey: connectionID)
        let affected = state.requests.values
            .filter { $0.connectionID == connectionID }
            .map(\.request.requestID)
        for requestID in affected {
            _ = attemptTerminal(
                requestID: requestID,
                connectionID: connectionID,
                result: .failed(.unavailable)
            )
        }
    }

    func transition(requestID: UUID, to newState: AutoFillRequestState) throws {
        let current = now()
        guard let existing = state.requests[requestID] else { throw Error.unknownRequest }
        guard existing.request.deadline > current else {
            _ = finish(requestID: requestID, connectionID: existing.connectionID, result: .timedOut)
            throw Error.deadlineExpired
        }
        guard AutoFillRequestRegistryState.canTransition(from: existing.state, to: newState) else {
            throw Error.invalidTransition
        }
        var updated = existing
        updated.state = newState
        state.requests[requestID] = updated
    }

    @discardableResult
    func complete(requestID: UUID, connectionID: UUID?) throws -> Bool {
        attemptTerminal(requestID: requestID, connectionID: connectionID, result: .completed)
    }

    @discardableResult
    func cancel(requestID: UUID, connectionID: UUID?) throws -> Bool {
        attemptTerminal(requestID: requestID, connectionID: connectionID, result: .cancelled)
    }

    @discardableResult
    func fail(
        requestID: UUID,
        connectionID: UUID?,
        failure: AutoFillBrokerFailure
    ) throws -> Bool {
        attemptTerminal(requestID: requestID, connectionID: connectionID, result: .failed(failure))
    }

    @discardableResult
    func expireTimedOutRequests() -> [UUID] {
        expireTimedOutRequests(at: now())
    }

    func terminalResult(for requestID: UUID) -> AutoFillRequestTerminal? {
        state.terminalEntries[requestID]?.result
    }

    func remainingTime(for requestID: UUID) throws -> Duration {
        let current = now()
        guard let entry = state.requests[requestID] else { throw Error.unknownRequest }
        guard entry.request.deadline > current else {
            _ = finish(requestID: requestID, connectionID: entry.connectionID, result: .timedOut)
            throw Error.deadlineExpired
        }
        return .nanoseconds(Int64(entry.request.deadline - current))
    }

    func waitForTerminal(requestID: UUID) async throws -> AutoFillRequestTerminal {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let terminal = state.terminalEntries[requestID]?.result {
                    continuation.resume(returning: terminal)
                    return
                }
                guard var entry = state.requests[requestID] else {
                    continuation.resume(throwing: Error.unknownRequest)
                    return
                }
                guard entry.continuation == nil else {
                    continuation.resume(throwing: Error.duplicateWaiter)
                    return
                }
                entry.continuation = continuation
                state.requests[requestID] = entry
            }
        } onCancel: {
            Task { await self.cancelFromWaitingTask(requestID: requestID) }
        }
    }

    func counts() -> Counts {
        Counts(
            pendingRequests: state.requests.count,
            wakeHandles: state.wakeHandles.count,
            connections: state.verifiedConnections.count,
            replayHistory: state.terminalEntries.count
        )
    }
}

private extension AutoFillRequestRegistry {
    private func cancelFromWaitingTask(requestID: UUID) {
        guard let entry = state.requests[requestID] else { return }
        _ = attemptTerminal(
            requestID: requestID,
            connectionID: entry.connectionID,
            result: .cancelled
        )
    }

    @discardableResult
    private func expireTimedOutRequests(at current: UInt64) -> [UUID] {
        let finished = state.expireTimedOutRequests(at: current)
        finished.forEach(finalize)
        return finished.map(\.entry.request.requestID)
    }

    private func expireWakeHandles(at current: UInt64) {
        state.expireWakeHandles(at: current).forEach(cancelLiveWakeExpiry)
    }

    private func pruneTerminalEntries(at current: UInt64) {
        state.pruneTerminalEntries(at: current)
    }

    private func pruneUsedWakeHandles(at current: UInt64) {
        state.pruneUsedWakeHandles(at: current).forEach(cancelUsedWakeExpiry)
    }

    private func attemptTerminal(
        requestID: UUID,
        connectionID: UUID?,
        result: AutoFillRequestTerminal
    ) -> Bool {
        guard let finished = state.attemptTerminal(
            requestID: requestID,
            connectionID: connectionID,
            result: result,
            current: now()
        ) else {
            return false
        }
        finalize(finished)
        return finished.result == result
    }

    private func finish(
        requestID: UUID,
        connectionID: UUID?,
        result: AutoFillRequestTerminal
    ) -> Bool {
        guard let finished = state.finish(
            requestID: requestID,
            connectionID: connectionID,
            result: result
        ) else {
            return false
        }
        finalize(finished)
        return true
    }

    private func finalize(_ finished: AutoFillRequestRegistryState.FinishedEntry) {
        finished.entry.timeoutTask?.cancel()
        finished.entry.continuation?.resume(returning: finished.result)
    }
    func armLiveWakeExpiry(for handle: UUID, deadline: UInt64, current: UInt64) {
        let delay = Duration.nanoseconds(Int64(deadline - current))
        state.liveWakeExpiryTasks[handle] = scheduleTimeout(delay) { [weak self] in
            await self?.liveWakeExpiryFired(handle: handle, deadline: deadline)
        }
    }

    func armUsedWakeExpiry(for handle: UUID, deadline: UInt64, current: UInt64) {
        let delay = Duration.nanoseconds(Int64(deadline - current))
        state.usedWakeExpiryTasks[handle] = scheduleTimeout(delay) { [weak self] in
            await self?.usedWakeExpiryFired(handle: handle, deadline: deadline)
        }
    }

    func cancelLiveWakeExpiry(for handle: UUID) {
        state.liveWakeExpiryTasks.removeValue(forKey: handle)?.cancel()
    }

    func cancelUsedWakeExpiry(for handle: UUID) {
        state.usedWakeExpiryTasks.removeValue(forKey: handle)?.cancel()
    }

    func liveWakeExpiryFired(handle: UUID, deadline: UInt64) {
        guard state.wakeHandles[handle]?.deadline == deadline else { return }
        let current = now()
        guard current >= deadline else {
            armLiveWakeExpiry(for: handle, deadline: deadline, current: current)
            return
        }
        state.wakeHandles.removeValue(forKey: handle)
        state.liveWakeExpiryTasks.removeValue(forKey: handle)
    }

    func usedWakeExpiryFired(handle: UUID, deadline: UInt64) {
        guard state.usedWakeHandles[handle] == deadline else { return }
        let current = now()
        guard current >= deadline else {
            armUsedWakeExpiry(for: handle, deadline: deadline, current: current)
            return
        }
        state.usedWakeHandles.removeValue(forKey: handle)
        state.usedWakeExpiryTasks.removeValue(forKey: handle)
    }

    func armTimeout(for requestID: UUID, deadline: UInt64, current: UInt64) {
        guard deadline > current else { return }
        let delay = Duration.nanoseconds(Int64(deadline - current))
        let task = scheduleTimeout(delay) { [weak self] in
            await self?.scheduledTimeoutFired(requestID: requestID, deadline: deadline)
        }
        state.requests[requestID]?.timeoutTask = task
    }

    func scheduledTimeoutFired(requestID: UUID, deadline: UInt64) {
        guard let entry = state.requests[requestID], entry.request.deadline == deadline else { return }
        let current = now()
        guard current >= deadline else {
            armTimeout(for: requestID, deadline: deadline, current: current)
            return
        }
        guard let finished = state.finish(requestID: requestID, result: .timedOut) else { return }
        finalize(finished)
    }
}
