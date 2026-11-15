import Dispatch
import Foundation
import os

/// Runs blocking work, such as code-signature validation, on a global queue instead of the cooperative pool.
/// Waiting for the result is bounded by a time budget and by the waiter's cancellation; the work itself always
/// runs to completion, and a result that is already available is returned even when no budget remains.
nonisolated final class BoundedBlockingWork<Value: Sendable>: Sendable {
    private enum Outcome: Sendable {
        case pending
        case done(Value)
    }

    private struct State: Sendable {
        var outcome = Outcome.pending
        var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]
        /// Waiters that timed out or were cancelled before they registered.
        var abandoned: Set<UUID> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ work: @escaping @Sendable () -> Value) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in complete(work()) }
    }

    /// The result, or nil when it is not ready within `nanoseconds` or the caller is cancelled first.
    func value(within nanoseconds: UInt64, sleep: @escaping @Sendable (UInt64) async throws -> Void) async -> Value? {
        if case .done(let value) = state.withLock({ $0.outcome }) { return value }
        guard nanoseconds > 0, !Task.isCancelled else { return nil }
        let id = UUID()
        let timer = Task { [self] in
            do { try await sleep(nanoseconds) } catch { return }
            abandon(id)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                let immediate: Value?? = state.withLock { state in
                    if case .done(let value) = state.outcome { return .some(value) }
                    if state.abandoned.remove(id) != nil { return .some(nil) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: { [self] in
            abandon(id)
        }
    }

    private func complete(_ value: Value) {
        let waiters = state.withLock { state in
            state.outcome = .done(value)
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    private func abandon(_ id: UUID) {
        let waiter = state.withLock { state -> CheckedContinuation<Value?, Never>? in
            if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
            if case .pending = state.outcome { state.abandoned.insert(id) }
            return nil
        }
        waiter?.resume(returning: nil)
    }
}
