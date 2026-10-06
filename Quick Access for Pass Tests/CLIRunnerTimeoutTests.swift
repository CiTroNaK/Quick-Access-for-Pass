import Testing
import Foundation
import os
@testable import Quick_Access_for_Pass

@Suite("CLIRunner timeout")
struct CLIRunnerTimeoutTests {

    /// Each selected native callback must consume fixture bytes inside an
    /// operation-owned I/O executor job before the child can exit. Removing
    /// that bridge's preference must fail its cases; quiescence cannot stand in.
    @Test(.timeLimit(.minutes(1)), arguments:
        [CLIRunner.LifecycleTesting.ReaderChannel.stdout, .stderr],
        [CLIRunner.LifecycleTesting.ReaderCallback.readSource, .poller])
    func nativeExitAndPipeWorkReachOperationOwnedExecutorsBeforeCompletion(
        channel: CLIRunner.LifecycleTesting.ReaderChannel,
        callback: CLIRunner.LifecycleTesting.ReaderCallback
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let release = directory.appendingPathComponent("release")
        defer {
            // Release any finite fixture loop even on a failed/cancelled run.
            try? Data([1]).write(to: release)
            try? FileManager.default.removeItem(at: directory)
        }
        let route = CLIRunner.LifecycleTesting.ReaderRoute(channel: channel, callback: callback)
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let reads = OSAllocatedUnfairLock(initialState: (placements: [Bool](), releaseFailed: false))
        let lifecycle = CLIRunner.LifecycleTesting(marker: { event in
            events.withLock { $0.append(String(describing: event)) }
        }, readerRouteUnderTest: route, readerCallbackRead: { observedRoute, inOwnedIOJob in
            guard observedRoute == route else { return }
            reads.withLock { $0.placements.append(inOwnedIOJob) }
            // No metadata lock spans this test-only fixture I/O.
            do { try Data([1]).write(to: release) }
            catch { reads.withLock { $0.releaseFailed = true } }
        })
        // Both pipes receive literal bytes. Only the selected native callback
        // is enabled until exit; the others are drained by normal quiescence.
        // The child has its own finite escape, independent of test scheduling.
        let script = """
        printf routed
        printf route-ready >&2
        attempt=0
        while [ ! -f "$1" ]; do
            [ "$attempt" -lt 200 ] || exit 91
            attempt=$((attempt + 1))
            /bin/sleep 0.005
        done
        """
        let executor = CLIRunnerTestTaskExecutor()
        let task = CLIRunnerTestTaskFactory.start(on: executor) {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", script, "route-fixture", release.path],
                timeout: 2, maximumOutputBytes: 1024, lifecycleTesting: lifecycle
            )
        }
        // This deliberately selected fixture executor is not a replacement for
        // the unchanged direct/default-caller inherited-writer regression.
        let output = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        #expect(output == Data("routed".utf8))
        let observed = events.withLock { $0 }
        let exitEntered = try #require(observed.firstIndex(of: "nativeExitTaskEntered"))
        let readEntered = try #require(observed.firstIndex(of: "stderrDrainEntered"))
        // Actual executor jobs must precede their first consumers. A control
        // job created later by finalization cannot satisfy the exit witness.
        #expect(observed[..<exitEntered].contains("controlExecutorJobStarted"))
        #expect(observed[..<readEntered].contains("ioExecutorJobStarted"))
        let callbackReads = reads.withLock { $0 }
        #expect(callbackReads.placements == [true],
                "Selected native reader callback did not consume bytes inside its operation-owned I/O executor job")
        #expect(!callbackReads.releaseFailed)
    }

    /// Exercises `CLIRunner.run`'s timeout path with a real `/bin/sleep 60`
    /// subprocess and a 1-second timeout. The `.timeLimit(.minutes(1))`
    /// trait ensures that if the timeout handling is genuinely broken and
    /// the call hangs waiting for the 60-second sleep, Swift Testing kills
    /// the test after 1 minute instead of blocking the entire suite.
    @Test(
        "cancelling an already launched run terminates its owned child promptly",
        .timeLimit(.minutes(1))
    )
    func cancellationAfterLaunchTerminatesProcess() async throws {
        let marker = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf launched > '\(marker.path)'; exec /bin/sleep 60"],
                timeout: 60
            )
        }
        try await waitForFixtureMarker(marker)

        let elapsed = await ContinuousClock().measure {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(elapsed < .seconds(2), "Cancellation took \(elapsed)")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledCallerCannotLaunchFixtureWhenItInvokesRunner() async throws {
        let invocationGate = OfflineTestGate()
        let startGate = OfflineTestGate()
        let marker = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let lifecycle = CLIRunner.LifecycleTesting(suspension: { point in
            if point == .beforeExecutionStart { try? await startGate.wait() }
        })
        let task = Task {
            // Deliberately continue after cancellation so this invocation enters
            // CLIRunner with Task.isCancelled already true.
            _ = try? await invocationGate.wait()
            return try await CLIRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf launched > '\(marker.path)'; exec /bin/sleep 3"],
                timeout: 3, maximumOutputBytes: nil, lifecycleTesting: lifecycle
            )
        }
        do {
            try await invocationGate.waitUntilEntered()
            task.cancel()
            try await startGate.waitUntilEntered()
            // Let the cancellation handler reach the actor before releasing
            // scheduled start; the fixture marker proves no Process was run.
            for _ in 0..<3 { await Task.yield() }
            await startGate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        } catch {
            task.cancel()
            await invocationGate.open()
            await startGate.open()
            _ = await task.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func submissionDeadlineExpiresBeforeScheduledStartWithoutLaunchingFixture() async throws {
        let startGate = OfflineTestGate()
        let marker = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let lifecycle = CLIRunner.LifecycleTesting(suspension: { point in
            if point == .beforeExecutionStart { try? await startGate.wait() }
        })
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf launched > '\(marker.path)'; exec /bin/sleep 3"],
                timeout: 0.1, maximumOutputBytes: nil, lifecycleTesting: lifecycle
            )
        }
        do {
            try await startGate.waitUntilEntered()
            try await Task.sleep(for: .milliseconds(200))
            await startGate.open()
            await #expect {
                try await task.value
            } throws: { error in
                guard let typed = error as? CLIError, case .timeout = typed else { return false }
                return true
            }
            #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        } catch {
            task.cancel()
            await startGate.open()
            _ = await task.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func inheritedPipeAndClosedEOFDoNotDelayTermination() async throws {
        let inheritedTrace = CLIRunnerFailureTrace()
        defer { inheritedTrace.report(caseName: "inheritedPipe") }
        let executor = CLIRunnerTestTaskExecutor(trace: inheritedTrace)
        let inheritedTask = CLIRunnerTestTaskFactory.start(on: executor) {
            try await inheritedTrace.call {
                try await CLIRunner.run(
                    executablePath: "/bin/sh", arguments: ["-c", "/bin/sleep 3 &"], timeout: 1,
                    maximumOutputBytes: nil, lifecycleTesting: inheritedTrace.lifecycle()
                )
            }
        }
        let inherited: Data
        do {
            inherited = try await inheritedTask.value
        } catch {
            inheritedTrace.recordFailure(error)
            throw error
        }
        #expect(inherited.isEmpty)
        inheritedTrace.expectCallCompletedWithinTwoSeconds()

        let closedEOFTrace = CLIRunnerFailureTrace()
        defer { closedEOFTrace.report(caseName: "closedEOF") }
        let closedEOFTask = CLIRunnerTestTaskFactory.start(on: executor) {
            try await closedEOFTrace.call {
                try await CLIRunner.run(
                    executablePath: "/bin/sh", arguments: ["-c", "exec 1>&-; /bin/sleep 3"], timeout: 0.2,
                    maximumOutputBytes: nil, lifecycleTesting: closedEOFTrace.lifecycle()
                )
            }
        }
        await #expect {
            try await closedEOFTask.value
        } throws: { error in
            guard let error = error as? CLIError, case .timeout = error else {
                closedEOFTrace.recordFailure(error)
                return false
            }
            return true
        }
        closedEOFTrace.expectCallCompletedWithinTwoSeconds()
    }

    @Test(
        "run() throws .timeout when subprocess exceeds timeout",
        .timeLimit(.minutes(1))
    )
    func timeoutThrowsCLIErrorTimeout() async throws {
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await #expect {
                _ = try await CLIRunner.run(
                    executablePath: "/bin/sleep",
                    arguments: ["60"],
                    timeout: 1.0
                )
            } throws: { error in
                guard let e = error as? CLIError, case .timeout = e else { return false }
                return true
            }
        }

        #expect(elapsed < .seconds(5), "CLIRunner.run took \(elapsed), expected < 5s")
    }

    @Test(.timeLimit(.minutes(1)))
    func ignoredTerminationCannotHoldRunnerForChildLifetime() async throws {
        let trace = CLIRunnerFailureTrace()
        let start = ContinuousClock.now
        await #expect {
            try await trace.call {
                try await CLIRunner.run(
                    executablePath: "/bin/sh",
                    arguments: ["-c", "trap '' TERM; /bin/sleep 3"],
                    timeout: 0.2, maximumOutputBytes: 4 * 1024, lifecycleTesting: trace.lifecycle()
                )
            }
        } throws: { error in
            guard let typed = error as? CLIError, case .timeout = typed else {
                trace.recordFailure(error)
                return false
            }
            return true
        }
        if start.duration(to: .now) >= .seconds(2) { trace.recordFailure() }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test(.timeLimit(.minutes(1)))
    func boundedOutputRejectsOverflowWithoutReturningPayload() async throws {
        await #expect {
            try await CLIRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "yes x | head -c 8192"],
                timeout: 2,
                maximumOutputBytes: 1024
            )
        } throws: { error in
            guard let typed = error as? CLIError, case .outputLimitExceeded = typed else { return false }
            return true
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func continuousIgnoredTerminationStdoutOverflowFailsPromptly() async throws {
        await expectContinuousOverflowFailure(
            arguments: ["-c", "trap '' TERM; i=0; while [ $i -lt 100000 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done"]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func continuousIgnoredTerminationStderrOverflowFailsPromptly() async throws {
        await expectContinuousOverflowFailure(
            arguments: ["-c", "trap '' TERM; i=0; while [ $i -lt 100000 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2; i=$((i+1)); done"]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func launchCancellationCannotRestoreRunningAfterStdoutInstallation() async throws {
        let gate = OfflineTestGate()
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(
            marker: { event in events.withLock { $0.append(event) } },
            suspension: { point in
                if point == .afterStdoutInstalled { try? await gate.wait() }
            }
        )
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", "yes x | head -c 8192; /bin/sleep 3"],
                timeout: 3, maximumOutputBytes: 1024, lifecycleTesting: lifecycle
            )
        }
        do {
            try await gate.waitUntilEntered()
            task.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
            let observed = events.withLock { $0 }
            #expect(observed.contains(.launching))
            #expect(observed.contains(.terminating))
            #expect(observed.contains(.running) == false)
            #expect(observed.filter { $0 == .completed }.count == 1)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func competingFinalizersRetainOutputAndClaimOwnershipOnce() async throws {
        let gate = OfflineTestGate()
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(
            marker: { event in events.withLock { $0.append(event) } },
            suspension: { point in
                if point == .afterFinalizationOwnership { try? await gate.wait() }
            }
        )
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", "printf retained-output"],
                timeout: 2, maximumOutputBytes: 4096, lifecycleTesting: lifecycle
            )
        }
        do {
            try await gate.waitUntilEntered()
            try await Task.sleep(for: .milliseconds(100))
            await gate.open()
            #expect(try await task.value == Data("retained-output".utf8))
            let observed = events.withLock { $0 }
            #expect(observed.filter { $0 == .finalizationOwned }.count == 1)
            #expect(observed.filter { $0 == .completed }.count == 1)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedInheritedWriterCannotExtendOrChangeReturnedOutput() async throws {
        let trace = CLIRunnerFailureTrace()
        let start = ContinuousClock.now
        let output = try await trace.call {
            try await CLIRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf early; (/bin/sleep 3; printf late) &"],
                timeout: 2, maximumOutputBytes: 1024, lifecycleTesting: trace.lifecycle()
            )
        }
        #expect(output == Data("early".utf8))
        if start.duration(to: .now) >= .seconds(2) { trace.recordFailure() }
        #expect(start.duration(to: .now) < .seconds(2))
        // The inherited writer is deliberately finite; let its owned fixture
        // lifetime conclude rather than leaving asynchronous test work behind.
        try await Task.sleep(for: .milliseconds(3100))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationWinsActualTimeoutTerminationRaceForNormalAndEnvironmentRuns() async throws {
        let normalEvents = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let normalTrace = CLIRunnerFailureTrace()
        let normal = Task {
            try await normalTrace.call {
                try await CLIRunner.run(
                    executablePath: "/bin/sh", arguments: ["-c", "trap '' TERM; /bin/sleep 3"],
                    timeout: 0.6, maximumOutputBytes: nil,
                    lifecycleTesting: normalTrace.lifecycle { event in normalEvents.withLock { $0.append(event) } }
                )
            }
        }
        try await waitForTerminationEvent(normalEvents)
        normal.cancel()
        await #expect(throws: CancellationError.self) { try await normal.value }
        if normalEvents.withLock({ $0.filter { $0 == .completed }.count }) != 1 { normalTrace.recordFailure() }
        #expect(normalEvents.withLock { $0.filter { $0 == .completed }.count } == 1)

        let environmentEvents = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let environmentTrace = CLIRunnerFailureTrace()
        let environment = Task {
            try await environmentTrace.call {
                try await CLIRunner.run(
                    executablePath: "/bin/sh", arguments: ["-c", "trap '' TERM; /bin/sleep 3"],
                    environmentOverrides: ["QA_RUNNER_VALUE": "unused"], timeout: 0.6, maximumOutputBytes: 1024,
                    lifecycleTesting: environmentTrace.lifecycle { event in environmentEvents.withLock { $0.append(event) } }
                )
            }
        }
        try await waitForTerminationEvent(environmentEvents)
        environment.cancel()
        await #expect(throws: CancellationError.self) { try await environment.value }
        if environmentEvents.withLock({ $0.filter { $0 == .completed }.count }) != 1 { environmentTrace.recordFailure() }
        #expect(environmentEvents.withLock { $0.filter { $0 == .completed }.count } == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func environmentAwareFinalizationRetainsCompleteOutputExactlyOnce() async throws {
        let gate = OfflineTestGate()
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(
            marker: { event in events.withLock { $0.append(event) } },
            suspension: { point in
                if point == .afterFinalizationOwnership { try? await gate.wait() }
            }
        )
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", "printf $QA_RUNNER_VALUE"],
                environmentOverrides: ["QA_RUNNER_VALUE": "environment-output"],
                timeout: 2, maximumOutputBytes: 1024, lifecycleTesting: lifecycle
            )
        }
        do {
            try await gate.waitUntilEntered()
            await gate.open()
            #expect(try await task.value == Data("environment-output".utf8))
            #expect(events.withLock { $0.filter { $0 == .finalizationOwned }.count } == 1)
            #expect(events.withLock { $0.filter { $0 == .completed }.count } == 1)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }
}

extension CLIRunnerTimeoutTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func outputOverflowDuringTimeoutCannotBecomeFallbackTimeout(stderr: Bool, delayedNotification: Bool) async throws {
        let fixture = NativeTimeoutOverflowFixture(stderr: stderr, delayedNotification: delayedNotification)
        defer { fixture.removeMarkers() }
        let executor = CLIRunnerTestTaskExecutor()
        let task = CLIRunnerTestTaskFactory.start(on: executor) {
            try await fixture.run(timeout: 2, maximumOutputBytes: 1024)
        }
        await #expect {
            try await task.value
        } throws: { error in
            guard let typed = error as? CLIError, case .outputLimitExceeded = typed else { return false }
            return true
        }
        fixture.expectTimeoutTrapAndSingleCompletion()
    }

    @Test(.timeLimit(.minutes(1)))
    func synchronousCancellationWinsQueuedExpiredStartBeforeActorCleanup() async throws {
        let startGate = OfflineTestGate()
        let cleanupGate = OfflineTestGate()
        let cleanupReleased = OSAllocatedUnfairLock(initialState: false)
        let marker = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let lifecycle = CLIRunner.LifecycleTesting(suspension: { point in
            switch point {
            case .beforeExecutionStart:
                try? await startGate.wait()
            case .beforeCancellationCleanup:
                try? await cleanupGate.wait()
                cleanupReleased.withLock { $0 = true }
            case .afterStdoutInstalled, .afterFinalizationOwnership, .beforeOutputLimitNotification:
                break
            }
        })
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf launched > '\(marker.path)'; exec /bin/sleep 3"],
                timeout: 0.1, maximumOutputBytes: nil, lifecycleTesting: lifecycle
            )
        }
        do {
            try await startGate.waitUntilEntered()
            task.cancel()
            try await cleanupGate.waitUntilEntered()
            try await Task.sleep(for: .milliseconds(200))
            await startGate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(FileManager.default.fileExists(atPath: marker.path) == false)
            await cleanupGate.open()
            for _ in 0..<100 where !cleanupReleased.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(cleanupReleased.withLock { $0 })
        } catch {
            task.cancel()
            await startGate.open()
            await cleanupGate.open()
            _ = await task.result
            throw error
        }
    }
}

private struct CLIRunnerFailureTrace: Sendable {
    private struct State: Sendable {
        var phases: [(String, UInt64)] = []
        var nextExecutorJob: UInt64 = 0
        var executorPhases: [(String, UInt64)] = []
        var droppedExecutorPhases = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func lifecycle(
        forwarding marker: @escaping @Sendable (CLIRunner.LifecycleTesting.Event) -> Void = { _ in }
    ) -> CLIRunner.LifecycleTesting {
        CLIRunner.LifecycleTesting(
            marker: { event in
                self.record("\(event)")
                marker(event)
            },
            suspension: { point in
                if point == .beforeExecutionStart { self.record("beforeExecutionStart") }
            }
        )
    }

    func call<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        record("callerCall")
        do {
            let value = try await operation()
            record("callerReturned")
            return value
        } catch {
            record("callerThrew")
            throw error
        }
    }

    func expectCallCompletedWithinTwoSeconds() {
        let phases = state.withLock { $0.phases }
        guard let started = phases.first(where: { $0.0 == "callerCall" })?.1,
              let completed = phases.last(where: { $0.0 == "callerReturned" || $0.0 == "callerThrew" })?.1
        else {
            Issue.record("CLIRunner trace was missing a caller boundary")
            return
        }
        let elapsed = completed - started
        if elapsed >= 2_000_000_000 { recordFailure() }
        #expect(elapsed < 2_000_000_000)
    }

    func recordFailure(_ error: (any Error)? = nil) {
        let phases = state.withLock { $0.phases }
            .map { "\($0.0)@\($0.1)" }
            .joined(separator: ",")
        let code: String
        switch error {
        case let error as CLIError:
            switch error {
            case .timeout: code = "CLIError.timeout"
            case .outputLimitExceeded: code = "CLIError.outputLimitExceeded"
            default: code = "CLIError.other"
            }
        case let error as CocoaError:
            code = "NSCocoaErrorDomain/\(error.code.rawValue)"
        case let error as POSIXError:
            code = "NSPOSIXErrorDomain/\(error.code.rawValue)"
        default:
            code = "none"
        }
        let executor = state.withLock { state in
            let phases = state.executorPhases.map { "\($0.0)@\($0.1)" }.joined(separator: ",")
            return "\(phases); dropped=\(state.droppedExecutorPhases)"
        }
        Issue.record("CLIRunner phase trace: \(phases); error=\(code); executor=\(executor)")
    }

    /// Capture successful diagnostic runs without recording an artificial failure.
    func report(caseName: String) {
        let snapshot = state.withLock { state in
            let phases = state.phases.map { "\($0.0)@\($0.1)" }.joined(separator: ",")
            let jobs = state.executorPhases.map { "\($0.0)@\($0.1)" }.joined(separator: ",")
            return "\(phases); executor=\(jobs); dropped=\(state.droppedExecutorPhases)"
        }
        print("CLIRunner diagnostic trace [\(caseName)]: \(snapshot)")
    }

    /// Test-local sequence numbers identify jobs, never threads, PIDs or descriptors.
    func executorJobSubmitted() -> UInt64 {
        state.withLock { state in
            let sequence = state.nextExecutorJob
            state.nextExecutorJob += 1
            appendExecutorPhase("job\(sequence)Enqueued", to: &state)
            return sequence
        }
    }

    func recordExecutorJob(_ sequence: UInt64, phase: String) {
        state.withLock { state in
            appendExecutorPhase("job\(sequence)\(phase)", to: &state)
        }
    }

    private func appendExecutorPhase(_ phase: String, to state: inout State) {
        guard state.executorPhases.count < 192 else {
            state.droppedExecutorPhases += 1
            return
        }
        state.executorPhases.append((phase, DispatchTime.now().uptimeNanoseconds))
    }

    private func record(_ phase: String) {
        state.withLock { state in
            guard state.phases.count < 64 else { return }
            state.phases.append((phase, DispatchTime.now().uptimeNanoseconds))
        }
    }
}

private func expectContinuousOverflowFailure(arguments: [String]) async {
    let trace = CLIRunnerFailureTrace()
    defer { trace.report(caseName: "continuousOverflow") }
    let executor = CLIRunnerTestTaskExecutor(trace: trace)
    let task = CLIRunnerTestTaskFactory.start(on: executor) {
        try await trace.call {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: arguments,
                timeout: 30, maximumOutputBytes: 1024, lifecycleTesting: trace.lifecycle()
            )
        }
    }
    await #expect {
        try await task.value
    } throws: { error in
        guard let typed = error as? CLIError, case .outputLimitExceeded = typed else {
            trace.recordFailure(error)
            return false
        }
        return true
    }
    trace.expectCallCompletedWithinTwoSeconds()
}

/// Submits a fixture from a nonisolated context so test-harness MainActor work
/// cannot consume its original runner budget before the actual invocation.
private enum CLIRunnerTestTaskFactory {
    nonisolated static func start<Value: Sendable>(
        on executor: CLIRunnerTestTaskExecutor,
        operation: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, Error> {
        Task(executorPreference: executor, operation: operation)
    }
}

private final class CLIRunnerTestTaskExecutor: TaskExecutor, Sendable {
    private let queue = DispatchQueue(label: "CLIRunnerTimeoutTests.executor")
    private let trace: CLIRunnerFailureTrace?

    init(trace: CLIRunnerFailureTrace? = nil) {
        self.trace = trace
    }

    func enqueue(_ job: UnownedJob) {
        let sequence = trace?.executorJobSubmitted()
        queue.async { [self, job] in
            if let sequence { trace?.recordExecutorJob(sequence, phase: "Began") }
            job.runSynchronously(on: asUnownedTaskExecutor())
            if let sequence { trace?.recordExecutorJob(sequence, phase: "Ended") }
        }
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

private func temporaryFixtureMarker() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("qa-cli-runner-\(UUID().uuidString).started")
}

private func waitForFixtureMarker(_ marker: URL) async throws {
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileNoSuchFile)
}

private func waitForTerminationEvent(
    _ events: OSAllocatedUnfairLock<[CLIRunner.LifecycleTesting.Event]>
) async throws {
    for _ in 0..<100 {
        if events.withLock({ $0.contains(.terminating) }) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadUnknown)
}
