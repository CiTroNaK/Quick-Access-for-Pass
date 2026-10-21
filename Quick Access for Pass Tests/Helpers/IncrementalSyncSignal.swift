import Synchronization

/// A one-shot metadata-only ordering event; no actor scheduling or sleeps are needed to observe it.
nonisolated final class IncrementalSyncSignal: Sendable {
    private let state = Mutex((fired: false, waiters: [CheckedContinuation<Void, Never>]()))
    func mark() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.fired { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
