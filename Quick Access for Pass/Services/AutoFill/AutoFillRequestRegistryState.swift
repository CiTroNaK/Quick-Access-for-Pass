import Foundation

nonisolated enum AutoFillRequestState: String, CaseIterable, Equatable, Sendable {
    case created
    case launching
    case connecting
    case awaitingUnlock
    case resolving
    case completed
    case cancelled
    case timedOut
    case failed
}

nonisolated enum AutoFillRequestTerminal: Equatable, Sendable {
    case completed
    case cancelled
    case timedOut
    case failed(AutoFillBrokerFailure)

    var state: AutoFillRequestState {
        switch self {
        case .completed: .completed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .failed: .failed
        }
    }
}

nonisolated struct AutoFillRegisteredRequest: Equatable, Sendable {
    let requestID: UUID
    let descriptorID: UUID
    let kind: AutoFillValueKind
    let deadline: UInt64
}

nonisolated struct AutoFillRequestRegistryState {
    struct Entry {
        let request: AutoFillRegisteredRequest
        var state: AutoFillRequestState
        var connectionID: UUID?
        var continuation: CheckedContinuation<AutoFillRequestTerminal, any Swift.Error>?
        var timeoutTask: Task<Void, Never>?
    }

    struct WakeEntry {
        let deadline: UInt64
    }

    struct TerminalEntry {
        let result: AutoFillRequestTerminal
        let deadline: UInt64
    }

    struct FinishedEntry {
        let entry: Entry
        let result: AutoFillRequestTerminal
    }

    var requests: [UUID: Entry] = [:]
    var terminalEntries: [UUID: TerminalEntry] = [:]
    var wakeHandles: [UUID: WakeEntry] = [:]
    var usedWakeHandles: [UUID: UInt64] = [:]
    var liveWakeExpiryTasks: [UUID: Task<Void, Never>] = [:]
    var usedWakeExpiryTasks: [UUID: Task<Void, Never>] = [:]
    var verifiedConnections: [UUID: VerifiedAutoFillPeer] = [:]
    var claimedWakeDeadlines: [UUID: UInt64] = [:]

    mutating func expireTimedOutRequests(at current: UInt64) -> [FinishedEntry] {
        let expired = requests.values
            .filter { $0.request.deadline <= current }
            .map(\.request.requestID)
            .sorted { $0.uuidString < $1.uuidString }
        return expired.compactMap { finish(requestID: $0, result: .timedOut) }
    }

    mutating func pruneTerminalEntries(at current: UInt64) {
        terminalEntries = terminalEntries.filter { $0.value.deadline > current }
    }

    mutating func expireWakeHandles(at current: UInt64) -> [UUID] {
        let expired = wakeHandles
            .filter { $0.value.deadline <= current }
            .map(\.key)
        for handle in expired {
            wakeHandles.removeValue(forKey: handle)
        }
        return expired
    }

    mutating func pruneUsedWakeHandles(at current: UInt64) -> [UUID] {
        let expired = usedWakeHandles
            .filter { $0.value <= current }
            .map(\.key)
        for handle in expired {
            usedWakeHandles.removeValue(forKey: handle)
        }
        return expired
    }

    mutating func attemptTerminal(
        requestID: UUID,
        connectionID: UUID?,
        result: AutoFillRequestTerminal,
        current: UInt64
    ) -> FinishedEntry? {
        guard let entry = requests[requestID], entry.connectionID == connectionID else {
            return nil
        }
        let terminal = entry.request.deadline > current ? result : .timedOut
        return finish(requestID: requestID, result: terminal)
    }

    mutating func finish(
        requestID: UUID,
        connectionID: UUID?,
        result: AutoFillRequestTerminal
    ) -> FinishedEntry? {
        guard let entry = requests[requestID], entry.connectionID == connectionID else {
            return nil
        }
        return finish(requestID: requestID, result: result)
    }

    mutating func finish(requestID: UUID, result: AutoFillRequestTerminal) -> FinishedEntry? {
        guard let entry = requests.removeValue(forKey: requestID) else { return nil }
        terminalEntries[requestID] = TerminalEntry(
            result: result,
            deadline: entry.request.deadline
        )
        return FinishedEntry(entry: entry, result: result)
    }
}

extension AutoFillRequestRegistry {
    nonisolated struct Limits: Sendable {
        let pendingRequests: Int
        let wakeHandles: Int
        let connections: Int
        let replayHistory: Int

        init(
            pendingRequests: Int = 64,
            wakeHandles: Int = 64,
            connections: Int = 64,
            replayHistory: Int = 256
        ) {
            self.pendingRequests = max(1, pendingRequests)
            self.wakeHandles = max(1, wakeHandles)
            self.connections = max(1, connections)
            self.replayHistory = max(1, replayHistory)
        }
    }

    nonisolated struct Counts: Equatable, Sendable {
        let pendingRequests: Int
        let wakeHandles: Int
        let connections: Int
        let replayHistory: Int
    }

    nonisolated enum Error: Swift.Error, Equatable, Sendable {
        case capacityExceeded
        case deadlineExpired
        case replayedRequest
        case replayedWake
        case unknownRequest
        case unverifiedConnection
        case connectionAlreadyBound
        case invalidWakeClaim
        case invalidTransition
        case duplicateWaiter
    }

}

extension AutoFillRequestRegistry {
    nonisolated static func defaultScheduleTimeout(
        after delay: Duration,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            await operation()
        }
    }
}

extension AutoFillRequestRegistryState {
    nonisolated static func addingClamped(_ duration: UInt64, to instant: UInt64) -> UInt64 {
        let (result, overflow) = instant.addingReportingOverflow(duration)
        return overflow ? UInt64.max : result
    }

    nonisolated static func canTransition(
        from oldState: AutoFillRequestState,
        to newState: AutoFillRequestState
    ) -> Bool {
        switch (oldState, newState) {
        case (.created, .launching),
             (.created, .connecting),
             (.launching, .connecting),
             (.connecting, .awaitingUnlock),
             (.connecting, .resolving),
             (.awaitingUnlock, .resolving):
            true
        default:
            false
        }
    }
}
