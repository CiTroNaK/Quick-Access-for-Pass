import Dispatch
import Foundation
import Synchronization

/// Non-secret one-shot signal usable from a synchronous writer/queue probe.
nonisolated final class SyncOrderingSignal: Sendable {
    private struct State: Sendable {
        var signalled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func signal() {
        let waiters = state.withLock { state in
            state.signalled = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard !state.signalled else { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Blocks only the native database writer, never a cooperative executor.
nonisolated final class SyncOrderingWriterGate: Sendable {
    let entered = SyncOrderingSignal()
    private let semaphore = DispatchSemaphore(value: 0)

    func hold() {
        entered.signal()
        semaphore.wait()
    }

    func open() { semaphore.signal() }
}
