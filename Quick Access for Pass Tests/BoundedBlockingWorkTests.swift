import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite(.timeLimit(.minutes(1)))
struct BoundedBlockingWorkTests {
    private static let longSleep: @Sendable (UInt64) async throws -> Void = { _ in try await Task.sleep(for: .seconds(30)) }

    @Test func returnsResultWithinBudget() async {
        let work = BoundedBlockingWork { 42 }
        #expect(await work.value(within: 5_000_000_000, sleep: Self.longSleep) == 42)
    }

    @Test func finishedResultIsReturnedWithoutBudget() async {
        let work = BoundedBlockingWork { "done" }
        _ = await work.value(within: 5_000_000_000, sleep: Self.longSleep)
        #expect(await work.value(within: 0, sleep: Self.longSleep) == "done")
    }

    @Test func timeoutReturnsNilWhileWorkBlocks() async {
        let gate = DispatchSemaphore(value: 0)
        let work = BoundedBlockingWork { gate.wait(); return 1 }
        #expect(await work.value(within: 1, sleep: { _ in }) == nil)
        gate.signal()
    }

    @Test func cancellationReturnsNilPromptly() async {
        let gate = DispatchSemaphore(value: 0)
        let work = BoundedBlockingWork { gate.wait(); return 1 }
        let waiter = Task { await work.value(within: 60_000_000_000, sleep: Self.longSleep) }
        waiter.cancel()
        #expect(await waiter.value == nil)
        gate.signal()
    }

    @Test func timerIsCancelledOnceResultArrives() async {
        let timerCancelled = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let work = BoundedBlockingWork { gate.wait(); return 7 }
        let value = await work.value(within: 60_000_000_000, sleep: { _ in
            // Release the work only once the timer runs, so the waiter really waits.
            gate.signal()
            do { try await Task.sleep(for: .seconds(30)) } catch {
                timerCancelled.withLock { $0 = true }
                throw error
            }
        })
        #expect(value == 7)
        while !timerCancelled.withLock({ $0 }) { await Task.yield() }
    }
}
