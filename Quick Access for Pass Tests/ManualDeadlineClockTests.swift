import Testing
@testable import Quick_Access_for_Pass

@Suite("Manual deadline clock", .timeLimit(.minutes(1)))
@MainActor
struct ManualDeadlineClockTests {
    @Test("A watchdog resumes at its deadline, not before it")
    func advanceResumesOnlyDueWatchdogs() async throws {
        let clock = ManualDeadlineClock()
        let task = Task { try await clock.sleep(for: .milliseconds(1)) }
        defer { task.cancel() }
        let registered = await waitForTestCondition { clock.pendingSleepCount == 1 }
        try #require(registered)

        clock.advance(to: 1_000_999_999)
        #expect(clock.pendingSleepCount == 1)
        clock.advance(to: 1_001_000_000)
        try await task.value

        #expect(clock.now == 1_001_000_000)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test("Cancellation cleans up before or after watchdog registration", arguments: [false, true])
    func cancellationRemovesWatchdog(cancelBeforeRegistration: Bool) async throws {
        let clock = ManualDeadlineClock()
        let task = Task { try await clock.sleep(for: .seconds(1)) }
        defer { task.cancel() }
        if !cancelBeforeRegistration {
            let registered = await waitForTestCondition { clock.pendingSleepCount == 1 }
            try #require(registered)
        }

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(clock.pendingSleepCount == 0)
        clock.advance(to: 2_000_000_000)
        #expect(clock.pendingSleepCount == 0)
    }
}
