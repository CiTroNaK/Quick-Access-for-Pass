import Foundation
import Testing
import os
@testable import Quick_Access_for_Pass

/// Entry and terminal settlement are distinct. A terminal runner may never
/// claim finalization; observing it must not leave an entry waiter stranded.
actor FinalizerSettlementObserver {
    enum Outcome: Sendable, Equatable { case entered, terminal }

    private var outcome: Outcome?
    private var observationStarted = false
    private var waiters: [UUID: CheckedContinuation<Outcome, any Error>] = [:]
    private var registrationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func finalizationEntered() { settle(.entered) }
    func runnerSettled() { settle(.terminal) }

    func pendingObservationCount() -> Int { waiters.count + registrationWaiters.count }
    func currentOutcome() -> Outcome? { outcome }

    func wait() async throws -> Outcome {
        try Task.checkCancellation()
        if let outcome { return outcome }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
                observationStarted = true
                let pending = registrationWaiters
                registrationWaiters.removeAll()
                for waiter in pending.values { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Acknowledges registration, not finalization entry or runner settlement.
    func waitUntilObserving() async throws {
        try Task.checkCancellation()
        if observationStarted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    registrationWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func settle(_ value: Outcome) {
        guard outcome == nil else { return }
        outcome = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.resume(returning: value) }
    }

    private func cancel(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
        } else if let waiter = registrationWaiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
        }
    }
}

// The observer regressions exercise real native terminal/entry boundaries.
extension CLIRunnerTimeoutTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func terminalFinalizerSettlementDoesNotStrandEntryObservation(environmentAware: Bool) async throws {
        let observer = FinalizerSettlementObserver()
        let gate = OfflineTestGate()
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(marker: { event in events.withLock { $0.append(event) } }, suspension: { point in
            if point == .afterFinalizationOwnership {
                await observer.finalizationEntered()
                try? await gate.wait()
            }
        })
        let runner = Task {
            try await CLIRunner.run(executablePath: "/bin/sh", arguments: ["-c", "printf must-not-run"],
                environmentOverrides: environmentAware ? ["QA_RUNNER_VALUE": "unused"] : [:],
                timeout: 0, maximumOutputBytes: 1024, lifecycleTesting: lifecycle)
        }
        let entry = Task { try await observer.wait() }
        let settlement = Task { _ = await runner.result; await observer.runnerSettled() }
        await settlement.value
        // Check terminal propagation before joining; a suppressed propagation
        // is a bounded assertion failure, not a wait for the test's time limit.
        let outcome = await observer.currentOutcome()
        #expect(outcome == .terminal)
        if outcome == nil { entry.cancel() }
        do {
            #expect(try await entry.value == .terminal)
        } catch { Issue.record(error) }
        await #expect { _ = try await runner.value } throws: { error in
            guard let error = error as? CLIError, case .timeout = error else { return false }
            return true
        }
        await gate.open()
        #expect(events.withLock { $0.contains(.launching) } == false)
        #expect(events.withLock { $0.contains(.finalizationOwned) } == false)
        #expect(events.withLock { $0.filter { $0 == .completed }.count } == 1)
        #expect(await observer.pendingObservationCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func finalizerObservationCancellationJoinsRunnerAndWatcher(environmentAware: Bool, whileGated: Bool) async throws {
        let observer = FinalizerSettlementObserver()
        let gate = OfflineTestGate()
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(marker: { event in events.withLock { $0.append(event) } }, suspension: { point in
            if point == .afterFinalizationOwnership {
                await observer.finalizationEntered()
                if whileGated { try? await gate.wait() }
            } else if point == .beforeExecutionStart && !whileGated {
                try? await gate.wait()
            }
        })
        let runner = Task {
            try await CLIRunner.run(executablePath: "/bin/sh", arguments: ["-c", "printf cancellation-fixture"],
                environmentOverrides: environmentAware ? ["QA_RUNNER_VALUE": "unused"] : [:],
                timeout: 2, maximumOutputBytes: 1024, lifecycleTesting: lifecycle)
        }
        let entry = Task { try await observer.wait() }
        let settlement = Task { _ = await runner.result; await observer.runnerSettled() }
        do {
            if whileGated {
                let outcome = try await entry.value
                if outcome == .terminal { _ = try await runner.value }
                try #require(outcome == .entered)
            } else {
                try await observer.waitUntilObserving()
            }
            try await gate.waitUntilEntered()
            entry.cancel()
            runner.cancel()
            await gate.open()
            if !whileGated {
                await #expect(throws: CancellationError.self) { try await entry.value }
            }
            await #expect(throws: CancellationError.self) { try await runner.value }
            await settlement.value
            #expect(await observer.pendingObservationCount() == 0)
            #expect(await observer.currentOutcome() == (whileGated ? .entered : .terminal))
            #expect(events.withLock { $0.contains(.finalizationOwned) } == whileGated)
            #expect(events.withLock { $0.filter { $0 == .completed }.count } == 1)
        } catch {
            entry.cancel()
            runner.cancel()
            await gate.open()
            _ = await entry.result
            _ = await runner.result
            await settlement.value
            throw error
        }
    }

}
