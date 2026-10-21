import Foundation
import os

/// A test-owned monotonic clock whose watchdogs advance only when the test advances time.
nonisolated final class ManualDeadlineClock: Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: UInt64
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(now: UInt64 = 1_000_000_000) {
        state = OSAllocatedUnfairLock(initialState: State(now: now))
    }

    var now: UInt64 { state.withLock { $0.now } }
    var pendingSleepCount: Int { state.withLock { $0.sleepers.count } }

    /// Sleeps in logical time; cancellation removes and resumes the registration exactly once.
    func sleep(for duration: Duration) async throws {
        let components = duration.components
        precondition(components.seconds >= 0 && components.attoseconds >= 0)
        let nanoseconds = UInt64(components.seconds) * 1_000_000_000
            + UInt64(components.attoseconds / 1_000_000_000)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    // Check under the registration lock: cancellation either sees
                    // this waiter or is already visible before it can be installed.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if nanoseconds == 0 { return .success(()) }
                    state.sleepers[id] = Sleeper(deadline: state.now + nanoseconds, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let sleeper = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances monotonically and resumes due watchdogs outside the lock.
    func advance(to instant: UInt64) {
        let due = state.withLock { state in
            precondition(instant >= state.now)
            state.now = instant
            let ids = state.sleepers.filter { $0.value.deadline <= instant }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
