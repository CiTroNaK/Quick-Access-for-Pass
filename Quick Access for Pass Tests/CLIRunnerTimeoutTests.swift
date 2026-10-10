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
        let startEntered = try #require(observed.firstIndex(of: "startTaskEntered"))
        #expect(observed[..<startEntered].contains("controlExecutorJobStarted"),
                "Native startup must be admitted on the operation-owned control executor")
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
        let executor = CLIRunnerTestTaskExecutor()
        let inheritedTask = CLIRunnerTestTaskFactory.start(on: executor) {
            try await inheritedTrace.call {
                try await CLIRunner.run(
                    executablePath: "/bin/sh", arguments: ["-c", "/bin/sleep 3 &"], timeout: 1,
                    maximumOutputBytes: nil, lifecycleTesting: inheritedTrace.lifecycle()
                )
            }
        }
        let inherited = try await inheritedTask.value
        inheritedTrace.expectEvents([.launching, .nativeExitCallbackEntered])
        inheritedTrace.expectSingleCompletion()
        #expect(inherited.isEmpty)
        inheritedTrace.expectCallCompleted()

        let closedEOFTrace = CLIRunnerFailureTrace()
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
            guard let error = error as? CLIError, case .timeout = error else { return false }
            return true
        }
        closedEOFTrace.expectEvents([.launching, .running, .terminating, .nativeExitCallbackEntered])
        closedEOFTrace.expectSingleCompletion()
        closedEOFTrace.expectCallCompleted()
    }

    @Test(
        "run() throws .timeout when subprocess exceeds timeout",
        .timeLimit(.minutes(1))
    )
    func timeoutThrowsCLIErrorTimeout() async throws {
        let trace = CLIRunnerFailureTrace()
        let child = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: child) }
        let executor = CLIRunnerTestTaskExecutor()
        await #expect {
            let task = CLIRunnerTestTaskFactory.start(on: executor) { try await trace.call { try await CLIRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf ready > '\(child.path)'; exec /bin/sleep 60"],
                timeout: 1.0, maximumOutputBytes: nil, lifecycleTesting: trace.lifecycle()
            ) } }
            _ = try await task.value
        } throws: { error in
            guard let typed = error as? CLIError, case .timeout = typed else { return false }
            return true
        }

        trace.expectChildReady(child)
        trace.expectEvents([.launching, .running, .terminating, .nativeExitCallbackEntered])
        trace.expectSingleCompletion()
        trace.expectCallCompleted(within: .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)))
    func ignoredTerminationCannotHoldRunnerForChildLifetime() async throws {
        let trace = CLIRunnerFailureTrace()
        let child = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: child) }
        let executor = CLIRunnerTestTaskExecutor()
        await #expect {
            let task = CLIRunnerTestTaskFactory.start(on: executor) { try await trace.call {
                try await CLIRunner.run(
                    executablePath: "/bin/sh",
                    arguments: ["-c", "trap '' TERM; printf ready > '\(child.path)'; /bin/sleep 3"],
                    timeout: 1, maximumOutputBytes: 4 * 1024, lifecycleTesting: trace.lifecycle()
                )
            } }
            _ = try await task.value
        } throws: { error in
            guard let typed = error as? CLIError, case .timeout = typed else { return false }
            return true
        }
        trace.expectChildReady(child)
        trace.expectEvents([.launching, .running, .terminating, .forceKillAttempted, .nativeExitCallbackEntered])
        trace.expectSingleCompletion()
        trace.expectCallCompleted()
    }

    @Test(.timeLimit(.minutes(1)))
    func boundedOutputRejectsOverflowWithoutReturningPayload() async throws {
        let trace = CLIRunnerFailureTrace()
        let child = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: child) }
        let executor = CLIRunnerTestTaskExecutor()
        await #expect {
            let task = CLIRunnerTestTaskFactory.start(on: executor) { try await trace.call { try await CLIRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf ready > '\(child.path)'; yes x | head -c 8192"],
                timeout: 2,
                maximumOutputBytes: 1024, lifecycleTesting: trace.lifecycle()
            ) } }
            _ = try await task.value
        } throws: { error in
            guard let typed = error as? CLIError, case .outputLimitExceeded = typed else { return false }
            return true
        }
        trace.expectChildReady(child)
        trace.expectEvents([.launching, .outputExceededEntered, .nativeExitCallbackEntered])
        trace.expectSingleCompletion()
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
        let trace = CLIRunnerFailureTrace()
        let gate = OfflineTestGate()
        let finalizationGate = OfflineTestGate()
        let child = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: child) }
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(
            marker: { event in trace.recordEvent(event); events.withLock { $0.append(event) } },
            suspension: { point in
                if point == .afterStdoutInstalled { try? await gate.wait() }
                if point == .afterFinalizationOwnership { try? await finalizationGate.wait() }
            }
        )
        let executor = CLIRunnerTestTaskExecutor()
        let task = CLIRunnerTestTaskFactory.start(on: executor) {
            try await trace.call {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", "printf ready > '\(child.path)'; yes x | head -c 8192; /bin/sleep 3"],
                timeout: 3, maximumOutputBytes: 1024, lifecycleTesting: lifecycle
            )
            }
        }
        do {
            try await gate.waitUntilEntered()
            try await finalizationGate.waitUntilEntered()
            trace.recordCancellationRequest()
            task.cancel()
            await finalizationGate.open()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
            trace.expectChildReady(child)
            trace.expectCancellation(beforeCommit: true)
            trace.expectSingleCompletion()
            let observed = events.withLock { $0 }
            #expect(observed.contains(.launching))
            #expect(observed.contains(.terminating))
            #expect(observed.contains(.running) == false)
            #expect(observed.filter { $0 == .completed }.count == 1)
        } catch {
            trace.recordCancellationRequest()
            task.cancel()
            await finalizationGate.open()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func competingFinalizersRetainOutputAndClaimOwnershipOnce() async throws {
        let gate = OfflineTestGate()
        let observer = FinalizerSettlementObserver()
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(
            marker: { event in events.withLock { $0.append(event) } },
            suspension: { point in
                if point == .afterFinalizationOwnership {
                    await observer.finalizationEntered()
                    try? await gate.wait()
                }
            }
        )
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", "printf retained-output"],
                timeout: 2, maximumOutputBytes: 4096, lifecycleTesting: lifecycle
            )
        }
        let settlement = Task { _ = await task.result; await observer.runnerSettled() }
        do {
            let outcome = try await observer.wait()
            if outcome == .terminal {
                // Preserve the actual native error; a no-finalization terminal
                // success also fails the required real-entry assertion.
                _ = try await task.value
            }
            try #require(outcome == .entered)
            try await gate.waitUntilEntered()
            try await Task.sleep(for: .milliseconds(100))
            await gate.open()
            #expect(try await task.value == Data("retained-output".utf8))
            await settlement.value
            #expect(await observer.pendingObservationCount() == 0)
            let observed = events.withLock { $0 }
            #expect(observed.contains(.launching))
            #expect(observed.filter { $0 == .finalizationOwned }.count == 1)
            #expect(observed.filter { $0 == .completed }.count == 1)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            await settlement.value
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedInheritedWriterCannotExtendOrChangeReturnedOutput() async throws {
        let trace = CLIRunnerFailureTrace()
        let executor = CLIRunnerTestTaskExecutor()
        let task = CLIRunnerTestTaskFactory.start(on: executor) {
            try await trace.call {
                try await CLIRunner.run(
                    executablePath: "/bin/sh",
                    arguments: ["-c", "printf early; (/bin/sleep 3; printf late) &"],
                    timeout: 2, maximumOutputBytes: 1024, lifecycleTesting: trace.lifecycle()
                )
            }
        }
        let output = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        trace.expectEvents([.launching, .nativeExitCallbackEntered])
        trace.expectSingleCompletion()
        #expect(output == Data("early".utf8))
        trace.expectCallCompleted()
        // The inherited writer is deliberately finite; let its owned fixture
        // lifetime conclude rather than leaving asynchronous test work behind.
        try await Task.sleep(for: .milliseconds(3100))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationWinsActualTimeoutTerminationRaceForNormalAndEnvironmentRuns() async throws {
        for environmentAware in [false, true] {
            let trace = CLIRunnerFailureTrace()
            let gate = OfflineTestGate()
            let child = temporaryFixtureMarker()
            defer { try? FileManager.default.removeItem(at: child) }
            let executor = CLIRunnerTestTaskExecutor()
            let lifecycle = trace.lifecycle(suspension: { point in
                if point == .afterFinalizationOwnership { try? await gate.wait() }
            })
            let task = CLIRunnerTestTaskFactory.start(on: executor) {
                try await trace.call {
                    let arguments = ["-c", "trap '' TERM; printf ready > '\(child.path)'; /bin/sleep 3"]
                    if environmentAware {
                        return try await CLIRunner.run(executablePath: "/bin/sh", arguments: arguments,
                            environmentOverrides: ["QA_RUNNER_VALUE": "unused"], timeout: 0.6, maximumOutputBytes: 1024, lifecycleTesting: lifecycle)
                    }
                    return try await CLIRunner.run(executablePath: "/bin/sh", arguments: arguments,
                        timeout: 0.6, maximumOutputBytes: nil, lifecycleTesting: lifecycle)
                }
            }
            do {
                try await gate.waitUntilEntered()
                trace.expectChildReady(child)
                trace.expectEvents([.running, .terminating, .forceKillAttempted, .nativeExitCallbackEntered, .finalizationOwned])
                trace.recordCancellationRequest()
                task.cancel()
                await gate.open()
                await #expect(throws: CancellationError.self) { _ = try await task.value }
                trace.expectCancellation(beforeCommit: true)
                trace.expectSingleCompletion()
            } catch {
                trace.recordCancellationRequest()
                task.cancel()
                await gate.open()
                _ = await task.result
                throw error
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationAfterCommittedTimeoutCannotRewriteResult(environmentAware: Bool) async throws {
        let trace = CLIRunnerFailureTrace()
        let committed = OfflineTestGate()
        let child = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: child) }
        let executor = CLIRunnerTestTaskExecutor()
        let lifecycle = trace.lifecycle(forwarding: { event in
            if event == .completed { Task { await committed.open() } }
        })
        let task = CLIRunnerTestTaskFactory.start(on: executor) {
            try await trace.call {
                let arguments = ["-c", "trap '' TERM; printf ready > '\(child.path)'; /bin/sleep 3"]
                if environmentAware {
                    return try await CLIRunner.run(executablePath: "/bin/sh", arguments: arguments,
                        environmentOverrides: ["QA_RUNNER_VALUE": "unused"], timeout: 0.6, maximumOutputBytes: 1024, lifecycleTesting: lifecycle)
                }
                return try await CLIRunner.run(executablePath: "/bin/sh", arguments: arguments,
                    timeout: 0.6, maximumOutputBytes: nil, lifecycleTesting: lifecycle)
            }
        }
        do {
            try await committed.wait()
            trace.recordCancellationRequest()
            task.cancel()
            await #expect { _ = try await task.value } throws: { error in
                guard let error = error as? CLIError, case .timeout = error else { return false }
                return true
            }
            trace.expectChildReady(child)
            trace.expectEvents([.running, .terminating, .forceKillAttempted, .nativeExitCallbackEntered])
            trace.expectCancellation(beforeCommit: false)
            trace.expectSingleCompletion()
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func environmentAwareFinalizationRetainsCompleteOutputExactlyOnce() async throws {
        let gate = OfflineTestGate()
        let observer = FinalizerSettlementObserver()
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(
            marker: { event in events.withLock { $0.append(event) } },
            suspension: { point in
                if point == .afterFinalizationOwnership {
                    await observer.finalizationEntered()
                    try? await gate.wait()
                }
            }
        )
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", "printf $QA_RUNNER_VALUE"],
                environmentOverrides: ["QA_RUNNER_VALUE": "environment-output"],
                timeout: 2, maximumOutputBytes: 1024, lifecycleTesting: lifecycle
            )
        }
        let settlement = Task { _ = await task.result; await observer.runnerSettled() }
        do {
            let outcome = try await observer.wait()
            if outcome == .terminal {
                // Preserve the actual native error; a no-finalization terminal
                // success also fails the required real-entry assertion.
                _ = try await task.value
            }
            try #require(outcome == .entered)
            try await gate.waitUntilEntered()
            await gate.open()
            #expect(try await task.value == Data("environment-output".utf8))
            await settlement.value
            #expect(await observer.pendingObservationCount() == 0)
            #expect(events.withLock { $0.contains(.launching) })
            #expect(events.withLock { $0.filter { $0 == .finalizationOwned }.count } == 1)
            #expect(events.withLock { $0.filter { $0 == .completed }.count } == 1)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            await settlement.value
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
        var phases: [String] = []
        var callStarted: UInt64?
        var callCompleted: UInt64?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func expectChildReady(_ marker: URL) {
        let ready = FileManager.default.fileExists(atPath: marker.path)
        #expect(ready)
    }
    func expectEvents(_ events: [CLIRunner.LifecycleTesting.Event]) {
        let names = state.withLock { $0.phases }
        for event in events { #expect(names.contains("\(event)")) }
    }
    func expectSingleCompletion() {
        #expect(state.withLock { $0.phases.filter { $0 == "completed" }.count } == 1)
    }
    func expectCancellation(beforeCommit: Bool) {
        let names = state.withLock { $0.phases }
        let cancellation = names.firstIndex(of: "cancellationRequest")
        let commit = names.firstIndex(of: "completed")
        #expect(cancellation != nil && commit != nil)
        if let cancellation, let commit { #expect((cancellation < commit) == beforeCommit) }
    }

    func recordCancellationRequest() { record("cancellationRequest") }
    func recordEvent(_ event: CLIRunner.LifecycleTesting.Event) { record("\(event)") }

    func lifecycle(
        forwarding marker: @escaping @Sendable (CLIRunner.LifecycleTesting.Event) -> Void = { _ in },
        suspension: (@Sendable (CLIRunner.LifecycleTesting.SuspensionPoint) async -> Void)? = nil
    ) -> CLIRunner.LifecycleTesting {
        CLIRunner.LifecycleTesting(
            marker: { event in
                self.record("\(event)")
                marker(event)
            },
            suspension: suspension
        )
    }

    func call<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        state.withLock { $0.callStarted = DispatchTime.now().uptimeNanoseconds }
        defer { state.withLock { $0.callCompleted = DispatchTime.now().uptimeNanoseconds } }
        return try await operation()
    }

    func expectCallCompleted(within limit: Duration = .seconds(2)) {
        let (started, completed) = state.withLock { ($0.callStarted, $0.callCompleted) }
        guard let started, let completed else {
            Issue.record("CLIRunner trace was missing a caller boundary")
            return
        }
        // Measure the actual runner call, not the outer test's later resumption.
        let elapsed = Duration.nanoseconds(Int64(completed - started))
        #expect(elapsed < limit)
    }

    private func record(_ phase: String) {
        state.withLock { state in
            guard state.phases.count < 64 else { return }
            state.phases.append(phase)
        }
    }
}

private func expectContinuousOverflowFailure(arguments: [String]) async {
    let trace = CLIRunnerFailureTrace()
    let executor = CLIRunnerTestTaskExecutor()
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
        guard let typed = error as? CLIError, case .outputLimitExceeded = typed else { return false }
        return true
    }
    trace.expectCallCompleted()
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

    func enqueue(_ job: UnownedJob) {
        queue.async { [self, job] in
            job.runSynchronously(on: asUnownedTaskExecutor())
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

extension CLIRunnerTimeoutTests {
    @Test(.timeLimit(.minutes(1)))
    func absoluteDeadlineExpiryAtGatedStartDoesNotLaunchProcess() async throws {
        let gate = OfflineTestGate()
        let marker = temporaryFixtureMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let deadlineTime = DispatchTime.now() + .seconds(1)
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: deadlineTime.uptimeNanoseconds)
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(marker: { event in events.withLock { $0.append(event) } }, suspension: { point in
            if point == .beforeExecutionStart { try? await gate.wait() }
        })
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: deadlineTime)
        timer.setEventHandler { Task { await gate.open() } }
        timer.resume()
        defer { timer.cancel() }
        let task = Task {
            try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", "printf launched > '\(marker.path)'"],
                deadline: deadline, maximumOutputBytes: nil, lifecycleTesting: lifecycle
            )
        }
        do {
            try await gate.waitUntilEntered()
            await #expect {
                try await task.value
            } throws: { error in
                guard let cliError = error as? CLIError, case .timeout = cliError else { return false }
                return true
            }
            #expect(FileManager.default.fileExists(atPath: marker.path) == false)
            #expect(events.withLock { $0.contains(.launching) } == false)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test func absoluteDeadlineDoesNotRefreshAfterQueueDelay() throws {
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: 3_000_000_000)
        #expect(try deadline.remainingSeconds(at: 2_500_000_000) == 0.5)
        do {
            _ = try deadline.remainingSeconds(at: 3_000_000_000)
            Issue.record("expired deadline should throw")
        } catch let error as CLIError {
            guard case .timeout = error else { Issue.record("expected timeout, received another CLIError"); return }
            #expect(true)
        } catch {
            Issue.record("expected CLIError.timeout, received \(error)")
        }
    }
}
