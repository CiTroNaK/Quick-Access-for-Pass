import Darwin
import Foundation
import os

/// Synchronously linearizes cancellation against a final result commit without
/// holding a lock across actor hops, process operations, or continuation resume.
nonisolated private final class CLIRunnerCancellationState: Sendable {
    nonisolated private enum State { case active, cancelled, completed }
    private let state = OSAllocatedUnfairLock(initialState: State.active)

    func recordCancellation() {
        state.withLock {
            guard $0 != .completed else { return }
            $0 = .cancelled
        }
    }

    func isCancelled() -> Bool {
        state.withLock { $0 == .cancelled }
    }

    /// Returns the classification that won before a continuation is consumed.
    func commitCompletion() -> Bool {
        state.withLock {
            let wasCancelled = $0 == .cancelled
            $0 = .completed
            return wasCancelled
        }
    }
}

nonisolated enum CLIError: Error, LocalizedError {
    case notInstalled
    case notLoggedIn
    case commandFailed(String)
    case timeout
    case outputLimitExceeded
    case secretFetchFailed
    case parseError(String)

    var isNotInstalled: Bool { if case .notInstalled = self { return true }; return false }
    var isAuthError: Bool {
        switch self {
        case .notLoggedIn: true
        case .commandFailed(let message): CLIRunner.stderrIndicatesNotLoggedIn(message)
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "pass-cli is not installed. Instructionas at https://protonpass.github.io/pass-cli/")
        case .notLoggedIn: String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in.")
        case .commandFailed(let message): String(localized: "pass-cli command failed: \(message)")
        case .timeout: String(localized: "pass-cli command timed out")
        case .outputLimitExceeded: String(localized: "pass-cli command produced too much output")
        case .secretFetchFailed: String(localized: "pass-cli could not retrieve the requested secret")
        case .parseError(let message): String(localized: "Failed to parse pass-cli output: \(message)")
        }
    }
}

nonisolated protocol CLIRunning: Sendable {
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data
}

extension CLIRunning {
    /// Fakes retain their old requirement but cannot bypass secret output limits.
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        let data = try await run(executablePath: executablePath, arguments: arguments, timeout: timeout)
        guard data.count <= maximumOutputBytes else { throw CLIError.outputLimitExceeded }
        return data
    }
}

nonisolated protocol CLIEnvironmentRunning: Sendable {
    func run(executablePath: String, arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval) async throws -> Data
}

nonisolated struct LiveCLIRunner: CLIRunning, CLIEnvironmentRunning {
    nonisolated func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await CLIRunner.run(executablePath: executablePath, arguments: arguments, timeout: timeout)
    }

    nonisolated func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        try await CLIRunner.run(executablePath: executablePath, arguments: arguments, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }

    nonisolated func run(executablePath: String, arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval) async throws -> Data {
        try await CLIRunner.run(executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides, timeout: timeout)
    }
}

/// A bounded, cancellation-aware native process lifecycle. Process ownership is
/// actor-isolated; pipe I/O is performed by Dispatch read sources on `ioQueue`.
nonisolated enum CLIRunner {
    /// Internal test-only lifecycle observation; it exposes no process IDs,
    /// descriptors, output, or secret material and is nil in production.
    nonisolated struct LifecycleTesting: Sendable {
        nonisolated enum Event: Sendable {
            case deadlineCaptured, startTaskSubmitted, startTaskEntered, actorStartEntered
            case launching, stdoutInstalled, running, terminating, finalizationAttempt, finalizationOwned, completed
            case outputLimitNotificationCompleted
            case stderrDrainSubmitted, stderrDrainEntered, stderrFirstBytesRead, stderrOverflowObserved
            case outputLimitNotificationSubmitted, outputLimitNotificationEntered, outputExceededEntered
            case nativeExitCallbackEntered, nativeExitTaskEntered, processDidExitEntered
            case timeoutTimerFired, timeoutTaskEntered, timeoutFoundationProcessRunning, timeoutFoundationProcessStopped
            case killTimerFired, killTaskEntered, killIfStillOwnedEntered, forceKillAttempted
            case controlExecutorJobStarted, ioExecutorJobStarted
        }
        /// `beforeExecutionStart` has captured a deadline but owns no child, PID, descriptor, or reader.
        nonisolated enum SuspensionPoint: Sendable {
            case beforeExecutionStart
            /// Cancellation is synchronously recorded, but actor cleanup has not started.
            case beforeCancellationCleanup
            case afterStdoutInstalled
            case afterFinalizationOwnership
            /// The reader's overflow flag is set; actor notification may be queued.
            case beforeOutputLimitNotification
        }

        nonisolated enum ReaderChannel: Sendable { case stdout, stderr }
        nonisolated enum ReaderCallback: Sendable { case readSource, poller }
        nonisolated struct ReaderRoute: Sendable, Equatable {
            let channel: ReaderChannel
            let callback: ReaderCallback
        }

        let marker: @Sendable (Event) -> Void
        let suspension: (@Sendable (SuspensionPoint) async -> Void)?
        /// Nil outside route tests; competing callbacks retain their sources
        /// and cancellation ownership but do not submit drain tasks in a test.
        let readerRouteUnderTest: ReaderRoute?
        let readerCallbackRead: (@Sendable (ReaderRoute, Bool) -> Void)?

        init(marker: @escaping @Sendable (Event) -> Void = { _ in },
             suspension: (@Sendable (SuspensionPoint) async -> Void)? = nil,
             readerRouteUnderTest: ReaderRoute? = nil,
             readerCallbackRead: (@Sendable (ReaderRoute, Bool) -> Void)? = nil) {
            self.marker = marker
            self.suspension = suspension
            self.readerRouteUnderTest = readerRouteUnderTest
            self.readerCallbackRead = readerCallbackRead
        }
    }

    private static let stderrLimit = 256 * 1024

    static func run(executablePath: String, arguments: [String], environmentOverrides: [String: String] = [:], timeout: TimeInterval = 300) async throws -> Data {
        try await run(executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides, timeout: timeout, maximumOutputBytes: nil)
    }

    static func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        try await run(executablePath: executablePath, arguments: arguments, environmentOverrides: [:], timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }

    static func run(executablePath: String, arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval, maximumOutputBytes: Int?) async throws -> Data {
        try await run(
            executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides,
            timeout: timeout, maximumOutputBytes: maximumOutputBytes, lifecycleTesting: nil
        )
    }

    static func run(
        executablePath: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        timeout: TimeInterval,
        maximumOutputBytes: Int?,
        lifecycleTesting: LifecycleTesting?
    ) async throws -> Data {
        // Capture the terminal deadline before the structured start child can
        // be queued. Native launch, SIGTERM grace, and SIGKILL all share it.
        let deadline = DispatchTime.now() + max(0, timeout)
        lifecycleTesting?.marker(.deadlineCaptured)
        let cancellationState = CLIRunnerCancellationState()
        let ioQueue = DispatchQueue(label: "com.quickaccess.pass.cli.io")
        let ioExecutor = CLIRunnerTaskExecutor(
            queue: ioQueue, lifecycleTesting: lifecycleTesting, event: .ioExecutorJobStarted
        )
        let controlExecutor = CLIRunnerTaskExecutor(
            queue: DispatchQueue(label: "com.quickaccess.pass.cli.control"),
            lifecycleTesting: lifecycleTesting, event: .controlExecutorJobStarted
        )
        let execution = Execution(
            executablePath: executablePath, arguments: arguments, environmentOverrides: environmentOverrides,
            timeout: timeout, deadline: deadline, cancellationState: cancellationState,
            stdoutLimit: maximumOutputBytes, stderrLimit: maximumOutputBytes == nil ? nil : stderrLimit,
            lifecycleTesting: lifecycleTesting, ioQueue: ioQueue,
            controlExecutor: controlExecutor, ioExecutor: ioExecutor
        )
        return try await withTaskCancellationHandler {
            // A structured child inherits the caller's task-executor preference;
            // plain Task {} would discard it. The group also joins start ownership.
            try await withThrowingTaskGroup(of: Void.self, returning: Data.self) { group in
                try await withCheckedThrowingContinuation { continuation in
                    lifecycleTesting?.marker(.startTaskSubmitted)
                    group.addTask {
                        lifecycleTesting?.marker(.startTaskEntered)
                        if let suspension = lifecycleTesting?.suspension { await suspension(.beforeExecutionStart) }
                        await execution.start(continuation)
                    }
                }
            }
        } onCancel: {
            cancellationState.recordCancellation()
            Task(executorPreference: controlExecutor) {
                if let suspension = lifecycleTesting?.suspension { await suspension(.beforeCancellationCleanup) }
                await execution.cancel()
            }
        }
    }

    private actor Execution {
        private enum Phase { case pendingLaunch, launching, running, terminating, completed }
        private enum TerminalReason { case timeout, outputLimit }

        private let executablePath: String
        private let arguments: [String]
        private let environmentOverrides: [String: String]
        private let timeout: TimeInterval
        private let stdoutLimit: Int?
        private let stderrLimit: Int?
        private let lifecycleTesting: LifecycleTesting?
        private let cancellationState: CLIRunnerCancellationState
        private let ioQueue: DispatchQueue
        private let controlExecutor: CLIRunnerTaskExecutor
        private let ioExecutor: CLIRunnerTaskExecutor
        private var phase: Phase = .pendingLaunch
        private var cancelled = false
        private var continuation: CheckedContinuation<Data, Error>?
        private var process: Process?
        // Keep both Pipe objects alive until reader shutdown; retaining only a
        // FileHandle can drop the stderr write endpoint before its final drain.
        private var outputPipe, errorPipe: Pipe?
        private var stdout, stderr: PipeReader?
        private var terminalReason: TerminalReason?
        private let deadline: DispatchTime
        private var timeoutTimer: DispatchSourceTimer?
        private var finalDrainTimer: DispatchSourceTimer?
        private var pendingDrains = 0
        private var exitedDuringLaunch = false
        private var observedExit = false
        private var finalizationOwned = false

        init(executablePath: String, arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval,
             deadline: DispatchTime, cancellationState: CLIRunnerCancellationState,
             stdoutLimit: Int?, stderrLimit: Int?, lifecycleTesting: LifecycleTesting?,
             ioQueue: DispatchQueue, controlExecutor: CLIRunnerTaskExecutor, ioExecutor: CLIRunnerTaskExecutor) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.environmentOverrides = environmentOverrides
            self.timeout = timeout
            self.deadline = deadline
            self.cancellationState = cancellationState
            self.stdoutLimit = stdoutLimit
            self.stderrLimit = stderrLimit
            self.lifecycleTesting = lifecycleTesting
            self.ioQueue = ioQueue
            self.controlExecutor = controlExecutor
            self.ioExecutor = ioExecutor
        }

        func start(_ continuation: CheckedContinuation<Data, Error>) async {
            lifecycleTesting?.marker(.actorStartEntered)
            guard phase == .pendingLaunch else { return }
            self.continuation = continuation
            guard !cancellationRequested else { await complete(.failure(CancellationError())); return }
            // A scheduler-delayed start has no remaining budget and must not
            // create a process or any observable launch side effect.
            guard deadline > .now() else {
                await complete(.failure(cancellationRequested ? CancellationError() : CLIError.timeout))
                return
            }
            phase = .launching
            lifecycleTesting?.marker(.launching)

            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            process.environment = CLIRunner.environment(overrides: environmentOverrides)
            let exitMarker = lifecycleTesting?.marker
            let controlExecutor = self.controlExecutor
            process.terminationHandler = { [self] _ in
                exitMarker?(.nativeExitCallbackEntered)
                Task(executorPreference: controlExecutor) {
                    exitMarker?(.nativeExitTaskEntered)
                    await self.processDidExit()
                }
            }
            self.process = process
            outputPipe = output
            errorPipe = error
            do {
                try process.run()
            } catch {
                await complete(.failure(cancellationRequested ? CancellationError() : CLIError.notInstalled))
                return
            }
            guard !cancellationRequested else { await beginTermination(reason: nil); return }

            let stdout = PipeReader(handle: output.fileHandleForReading, limit: stdoutLimit,
                                    channel: .stdout, lifecycleTesting: lifecycleTesting)
            let stderr = PipeReader(handle: error.fileHandleForReading, limit: stderrLimit,
                                    channel: .stderr, lifecycleTesting: lifecycleTesting)
            self.stdout = stdout
            self.stderr = stderr
            await stdout.start(on: ioQueue, executor: ioExecutor) { [self] in Task(executorPreference: controlExecutor) {
                if let suspension = self.lifecycleTesting?.suspension { await suspension(.beforeOutputLimitNotification) }
                await self.outputExceeded()
                self.lifecycleTesting?.marker(.outputLimitNotificationCompleted)
            } }
            lifecycleTesting?.marker(.stdoutInstalled)
            if let suspension = lifecycleTesting?.suspension {
                await suspension(.afterStdoutInstalled)
            }
            // Cancellation and an early reader overflow can race this suspension.
            // A terminating launch must never install more readers or replace its
            // already-owned kill timer with a new running timeout.
            guard phase == .launching, !cancellationRequested else { return }
            let overflowMarker = lifecycleTesting?.marker
            await stderr.start(on: ioQueue, executor: ioExecutor) { [self] in
                overflowMarker?(.outputLimitNotificationSubmitted)
                Task(executorPreference: controlExecutor) {
                    overflowMarker?(.outputLimitNotificationEntered)
                    if let suspension = self.lifecycleTesting?.suspension { await suspension(.beforeOutputLimitNotification) }
                    await self.outputExceeded()
                    self.lifecycleTesting?.marker(.outputLimitNotificationCompleted)
                }
            }
            guard phase == .launching, !cancellationRequested else { return }
            phase = .running
            lifecycleTesting?.marker(.running)
            scheduleTimeoutTermination()
            if exitedDuringLaunch { await processDidExit() }
        }

        func cancel() async {
            cancellationState.recordCancellation()
            cancelled = true
            guard phase != .completed else { return }
            if phase == .pendingLaunch { return }
            await beginTermination(reason: nil)
        }

        private func scheduleTimeoutTermination() {
            let grace = min(0.25, max(0, timeout) / 2)
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: deadline - grace)
            let marker = lifecycleTesting?.marker
            let executor = controlExecutor
            timer.setEventHandler { [weak self] in
                marker?(.timeoutTimerFired)
                Task(executorPreference: executor) {
                    marker?(.timeoutTaskEntered)
                    await self?.beginTermination(reason: .timeout)
                }
            }
            timeoutTimer = timer
            timer.resume()
        }

        private func outputExceeded() async {
            lifecycleTesting?.marker(.outputExceededEntered)
            // Readers may observe a one-shot overflow while launch is suspended.
            // Preserve it as a terminal event instead of dropping it before the
            // lifecycle transitions to running.
            guard phase == .launching || phase == .running || phase == .terminating else { return }
            await beginTermination(reason: .outputLimit)
        }

        private func beginTermination(reason: TerminalReason?) async {
            guard phase != .completed else { return }
            // Foundation's state is diagnostic metadata, not a native exit-time
            // proof or a new classification/authorization decision.
            if reason == .timeout, let marker = lifecycleTesting?.marker, let process {
                marker(process.isRunning ? .timeoutFoundationProcessRunning : .timeoutFoundationProcessStopped)
            }
            // Overflow is non-fallback even when timeout already owns termination.
            // The existing terminating-phase guard preserves that kill timer.
            if let reason, terminalReason == nil || reason == .outputLimit { terminalReason = reason }
            guard let process else {
                await complete(.failure(cancellationRequested ? CancellationError() : CLIError.timeout))
                return
            }
            guard phase != .terminating else { return }
            phase = .terminating
            lifecycleTesting?.marker(.terminating)
            process.terminate()
            timeoutTimer?.cancel()
            let killTimer = DispatchSource.makeTimerSource()
            let graceDeadline: DispatchTime = switch reason {
            case .timeout:
                deadline
            case .outputLimit, nil:
                min(deadline, .now() + .milliseconds(250))
            }
            killTimer.schedule(deadline: graceDeadline)
            let marker = lifecycleTesting?.marker
            let executor = controlExecutor
            killTimer.setEventHandler { [weak self] in
                marker?(.killTimerFired)
                Task(executorPreference: executor) {
                    marker?(.killTaskEntered)
                    await self?.killIfStillOwned()
                }
            }
            timeoutTimer = killTimer
            killTimer.resume()
        }

        private func killIfStillOwned() {
            lifecycleTesting?.marker(.killIfStillOwnedEntered)
            // A timer can enqueue after the child is reaped but before the exit
            // task enters this actor. Both observed exit and Foundation's live
            // process state are required before signalling the owned PID.
            guard phase == .terminating, !observedExit, let process, process.isRunning else { return }
            lifecycleTesting?.marker(.forceKillAttempted)
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }

        private func processDidExit() async {
            lifecycleTesting?.marker(.processDidExitEntered)
            observedExit = true
            guard phase != .completed else { return }
            guard phase != .launching else { exitedDuringLaunch = true; return }
            timeoutTimer?.cancel()
            timeoutTimer = nil
            let readers = [stdout, stderr].compactMap { $0 }
            guard !readers.isEmpty else { await finalizeExitedProcess(); return }
            pendingDrains = readers.count
            let controlExecutor = self.controlExecutor
            let ioExecutor = self.ioExecutor
            for reader in readers {
                Task(executorPreference: controlExecutor) { [weak self, reader] in
                    // Default actors follow a task's preference. Restrict pipe
                    // work to this region, then restore control for finalization.
                    await withTaskExecutorPreference(ioExecutor) { await reader.quiesce() }
                    await self?.readerDidQuiesce()
                }
            }
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + .milliseconds(50))
            timer.setEventHandler { [weak self] in
                Task(executorPreference: controlExecutor) { await self?.finalizeExitedProcess() }
            }
            finalDrainTimer = timer
            timer.resume()
        }

        private func readerDidQuiesce() async {
            guard phase != .completed, pendingDrains > 0 else { return }
            pendingDrains -= 1
            if pendingDrains == 0 { await finalizeExitedProcess() }
        }

        private func finalizeExitedProcess() async {
            guard phase != .completed else { return }
            lifecycleTesting?.marker(.finalizationAttempt)
            guard !finalizationOwned else { return }
            finalizationOwned = true
            lifecycleTesting?.marker(.finalizationOwned)
            if let suspension = lifecycleTesting?.suspension {
                await suspension(.afterFinalizationOwnership)
            }
            finalDrainTimer?.cancel()
            finalDrainTimer = nil
            if cancellationRequested { await complete(.failure(CancellationError())); return }
            let outputReader = stdout
            let errorReader = stderr
            let (stdoutOverflow, stderrOverflow) = await withTaskExecutorPreference(ioExecutor) {
                let output = if let outputReader { await outputReader.didOverflow() } else { false }
                let error = if let errorReader { await errorReader.didOverflow() } else { false }
                return (output, error)
            }
            if stdoutOverflow || stderrOverflow || terminalReason == .outputLimit {
                await complete(.failure(CLIError.outputLimitExceeded))
                return
            }
            if terminalReason == .timeout {
                await complete(.failure(CLIError.timeout))
                return
            }
            guard let process else { await complete(.failure(CLIError.notInstalled)); return }
            var (output, error) = await withTaskExecutorPreference(ioExecutor) {
                let output = await outputReader?.takeData() ?? Data()
                let error = await errorReader?.takeData() ?? Data()
                return (output, error)
            }
            defer { CLIRunner.zero(&output); CLIRunner.zero(&error) }
            do { await complete(.success(try CLIRunner.result(for: process, stdout: output, stderr: error))) }
            catch { await complete(.failure(error)) }
        }

        private var cancellationRequested: Bool {
            cancelled || cancellationState.isCancelled()
        }

        private func complete(_ result: Result<Data, Error>) async {
            guard phase != .completed else { return }
            let result = cancellationState.commitCompletion() ? Result<Data, Error>.failure(CancellationError()) : result
            phase = .completed
            lifecycleTesting?.marker(.completed)
            timeoutTimer?.cancel()
            finalDrainTimer?.cancel()
            timeoutTimer = nil
            finalDrainTimer = nil
            let continuation = continuation
            self.continuation = nil
            let readers = [stdout, stderr].compactMap { $0 }
            await withTaskExecutorPreference(ioExecutor) {
                for reader in readers { await reader.stopAndZero() }
            }
            stdout = nil
            stderr = nil
            outputPipe = nil
            errorPipe = nil
            process?.terminationHandler = nil
            process = nil
            continuation?.resume(with: result)
        }
    }

    private static func result(for process: Process, stdout: Data, stderr: Data) throws -> Data {
        if process.terminationStatus == 0 { return stdout }
        let errorOutput = String(data: stderr, encoding: .utf8) ?? ""
        if stderrIndicatesNotLoggedIn(errorOutput) { throw CLIError.notLoggedIn }
        throw CLIError.commandFailed(errorOutput)
    }

    fileprivate static func zero(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: 0..<data.count)
    }

    private static func environment(overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        for (key, value) in overrides { env[key] = value }
        return env
    }

    static func stderrIndicatesNotLoggedIn(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("not logged in") || lowered.contains("please log in") || lowered.contains("there is no session") || lowered.contains("failed to authenticate: non-existent session")
    }
}

/// Allocated only for a test observer. Its lock protects one-shot metadata
/// flags, never pipe I/O, actor hops or observer callbacks.
nonisolated private final class CLIPipeReaderObservation: Sendable {
    private let flags = OSAllocatedUnfairLock(initialState: UInt8(0))
    private let marker: @Sendable (CLIRunner.LifecycleTesting.Event) -> Void

    init(marker: @escaping @Sendable (CLIRunner.LifecycleTesting.Event) -> Void) {
        self.marker = marker
    }

    func recordFirst(_ event: CLIRunner.LifecycleTesting.Event) {
        let bit: UInt8 = switch event {
        case .stderrDrainSubmitted: 1
        case .stderrDrainEntered: 2
        case .stderrFirstBytesRead: 4
        case .stderrOverflowObserved: 8
        default: 0
        }
        guard bit != 0 else { return }
        let isFirst = flags.withLock { flags in
            guard flags & bit == 0 else { return false }
            flags |= bit
            return true
        }
        if isFirst { marker(event) }
    }
}

/// Selects execution placement, not actor isolation or a real-time guarantee.
/// Tasks retain this operation-owned executor; each enqueued job also retains
/// it until that job has run. No synchronous queue waits or shutdown barriers.
nonisolated private final class CLIRunnerTaskExecutor: TaskExecutor, Sendable {
    private let queue: DispatchQueue
    private let observation: CLIExecutorObservation?
    private let jobContextForTesting: CLIExecutorJobContext?

    init(queue: DispatchQueue, lifecycleTesting: CLIRunner.LifecycleTesting?, event: CLIRunner.LifecycleTesting.Event) {
        self.queue = queue
        observation = lifecycleTesting.map { CLIExecutorObservation(marker: $0.marker, event: event) }
        if lifecycleTesting?.readerCallbackRead != nil, case .ioExecutorJobStarted = event {
            jobContextForTesting = CLIExecutorJobContext()
        } else {
            jobContextForTesting = nil
        }
    }

    func enqueue(_ job: UnownedJob) {
        queue.async { [self, job] in
            observation?.recordFirstJob()
            if let context = jobContextForTesting {
                context.run { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
            } else {
                job.runSynchronously(on: asUnownedTaskExecutor())
            }
        }
    }

    func isExecutingJobForTesting() -> Bool {
        jobContextForTesting?.isCurrentJob() == true
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

/// Allocated only for route tests. Foundation's dictionary is accessed only
/// synchronously on its owning thread; it is never stored or sent elsewhere.
/// The private operation key marks this exact synchronous executor job, not a
/// native Dispatch callback on the same queue, an earlier job or task-local
/// inheritance. Restore any predecessor value when the job returns/suspends.
nonisolated private final class CLIExecutorJobContext: Sendable {
    private let key = "com.quickaccess.pass.cli.test-job." + UUID().uuidString

    func run(_ body: () -> Void) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = true
        defer {
            if let previous { dictionary[key] = previous }
            else { dictionary.removeObject(forKey: key) }
        }
        body()
    }

    func isCurrentJob() -> Bool {
        Thread.current.threadDictionary[key] as? Bool == true
    }
}

/// Nil in production. The metadata lock is released before callbacks or jobs.
nonisolated private final class CLIExecutorObservation: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: false)
    private let marker: @Sendable (CLIRunner.LifecycleTesting.Event) -> Void
    private let event: CLIRunner.LifecycleTesting.Event

    init(marker: @escaping @Sendable (CLIRunner.LifecycleTesting.Event) -> Void, event: CLIRunner.LifecycleTesting.Event) {
        self.marker = marker
        self.event = event
    }

    func recordFirstJob() {
        let first = recorded.withLock { recorded in
            guard !recorded else { return false }
            recorded = true
            return true
        }
        if first { marker(event) }
    }
}

private actor PipeReader {
    private let handle: FileHandle
    private let limit: Int?
    private let observation: CLIPipeReaderObservation?
    private let channel: CLIRunner.LifecycleTesting.ReaderChannel
    private let readerRouteUnderTest: CLIRunner.LifecycleTesting.ReaderRoute?
    private let readerCallbackRead: (@Sendable (CLIRunner.LifecycleTesting.ReaderRoute, Bool) -> Void)?
    private var callbackExecutorForTesting: CLIRunnerTaskExecutor?
    private var didReportCallbackRead = false
    private var source: DispatchSourceRead?
    /// A short nonblocking fallback prevents a dispatch-read delivery race
    /// from delaying an overflow until the child exits.
    private var poller: DispatchSourceTimer?
    private var data = Data()
    private var discarded = false
    private var overflowed = false
    private var didQuiesce = false
    private var onOverflow: (@Sendable () -> Void)?

    init(handle: FileHandle, limit: Int?, channel: CLIRunner.LifecycleTesting.ReaderChannel,
         lifecycleTesting: CLIRunner.LifecycleTesting? = nil) {
        self.handle = handle
        self.limit = limit
        self.channel = channel
        readerRouteUnderTest = lifecycleTesting?.readerRouteUnderTest
        readerCallbackRead = lifecycleTesting?.readerCallbackRead
        // Existing stderr diagnostics must not accidentally describe stdout.
        observation = channel == .stderr ? lifecycleTesting.map { CLIPipeReaderObservation(marker: $0.marker) } : nil
    }

    func start(on queue: DispatchQueue, executor: CLIRunnerTaskExecutor, onOverflow: @escaping @Sendable () -> Void) {
        self.onOverflow = onOverflow
        if readerCallbackRead != nil { callbackExecutorForTesting = executor }
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        let observation = observation
        let sourceRoute = CLIRunner.LifecycleTesting.ReaderRoute(channel: channel, callback: .readSource)
        let pollerRoute = CLIRunner.LifecycleTesting.ReaderRoute(channel: channel, callback: .poller)
        let enableSource = readerRouteUnderTest.map { $0 == sourceRoute } ?? true
        let enablePoller = readerRouteUnderTest.map { $0 == pollerRoute } ?? true
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self, observation] in
            guard enableSource else { return }
            observation?.recordFirst(.stderrDrainSubmitted)
            Task(executorPreference: executor) { await self?.drain(callback: .readSource) }
        }
        source.setCancelHandler { [handle] in try? handle.close() }
        self.source = source
        source.resume()
        let poller = DispatchSource.makeTimerSource(queue: queue)
        poller.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        poller.setEventHandler { [weak self, observation] in
            guard enablePoller else { return }
            observation?.recordFirst(.stderrDrainSubmitted)
            Task(executorPreference: executor) { await self?.drain(callback: .poller) }
        }
        self.poller = poller
        poller.resume()
    }

    func quiesce() async {
        await drain()
        while !didQuiesce && !discarded {
            await Task.yield()
            await drain()
        }
    }

    func takeData() -> Data {
        defer { data = Data() }
        return data
    }

    func didOverflow() -> Bool { overflowed }

    func stopAndZero() {
        discarded = true
        source?.cancel()
        poller?.cancel()
        source = nil
        poller = nil
        callbackExecutorForTesting = nil
        CLIRunner.zero(&data)
    }

    private func drain(callback: CLIRunner.LifecycleTesting.ReaderCallback? = nil) async {
        // Capture placement at actor entry, before this drain can suspend.
        // Quiescence supplies no callback tag and cannot report a route read.
        let inOwnedIOJob = callback != nil && readerCallbackRead != nil
            ? callbackExecutorForTesting?.isExecutingJobForTesting() == true : false
        observation?.recordFirst(.stderrDrainEntered)
        guard !discarded else { return }
        for index in 0..<8 {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                observation?.recordFirst(.stderrFirstBytesRead)
                if let callback, let readerCallbackRead, !didReportCallbackRead {
                    didReportCallbackRead = true
                    readerCallbackRead(.init(channel: channel, callback: callback), inOwnedIOJob)
                }
                let chunk = Data(bytes.prefix(Int(count)))
                if let limit, data.count > limit - chunk.count {
                    overflowed = true
                    discarded = true
                    CLIRunner.zero(&data)
                    observation?.recordFirst(.stderrOverflowObserved)
                    onOverflow?()
                    return
                }
                data.append(chunk)
                if index == 7 { return }
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                didQuiesce = true
            }
            return
        }
    }
}
