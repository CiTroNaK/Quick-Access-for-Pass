import Foundation
import os

/// Once-finalizable locked box. Writes via `setIfNotFinalized` are accepted
/// until `finalize(_:)` is called, after which further writes drop silently.
///
/// Used to bridge the `DispatchSemaphore + async Task` pattern in proxy
/// handlers: the outer GCD thread spawns a detached Task to call an async
/// auth handler, then waits on the semaphore with a timeout. If the wait
/// times out, the outer thread calls `finalize(fallback)` so that any late
/// write from the still-running Task is dropped.
///
/// Thread-safe via `OSAllocatedUnfairLock`. `@unchecked Sendable` is
/// justified because all state is guarded by the lock.
nonisolated final class FinalizableBox<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var value: Value
        var finalized: Bool
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(initial: Value) {
        self.lock = OSAllocatedUnfairLock(initialState: State(value: initial, finalized: false))
    }

    /// Write a new value unless `finalize(_:)` has already been called.
    /// Called by the in-flight Task when its async work completes.
    func setIfNotFinalized(_ new: Value) {
        lock.withLock { state in
            guard !state.finalized else { return }
            state.value = new
        }
    }

    /// Mark the box finalized and install the final value. Subsequent
    /// `setIfNotFinalized(_:)` calls drop. Called by the outer thread on
    /// timeout to install a fallback and block late writes. Returns the
    /// final value so the caller can use it directly.
    @discardableResult
    func finalize(_ fallback: Value) -> Value {
        lock.withLock { state in
            state.finalized = true
            state.value = fallback
            return state.value
        }
    }

    /// Read the current value. Used by the outer thread when the semaphore
    /// signalled before timeout (the Task's write already landed).
    var value: Value {
        lock.withLock { $0.value }
    }
}
