import Darwin
import Foundation
import os

/// Synchronously linearizes cancellation against a final result commit without
/// holding a lock across actor hops, process operations, or continuation resume.
nonisolated final class CLIRunnerCancellationState: Sendable {
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

actor CLIExecution {
    private enum Phase { case pendingLaunch, launching, running, terminating, completed }
    private enum TerminalReason { case timeout, outputLimit }

    private let executablePath: String
    private let arguments: [String]
    private let environmentOverrides: [String: String]
    private let timeout: TimeInterval
    private let stdoutLimit: Int?
    private let stderrLimit: Int?
    private let lifecycleTesting: CLIRunner.LifecycleTesting?
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
    private var stdout, stderr: CLIPipeReader?
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
         stdoutLimit: Int?, stderrLimit: Int?, lifecycleTesting: CLIRunner.LifecycleTesting?,
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

        let (process, output, error) = prepareProcess()
        do {
            try process.run()
        } catch {
            await complete(.failure(cancellationRequested ? CancellationError() : CLIError.notInstalled))
            return
        }
        guard !cancellationRequested else { await beginTermination(reason: nil); return }

        let stdout = CLIPipeReader(handle: output.fileHandleForReading, limit: stdoutLimit,
                                channel: .stdout, lifecycleTesting: lifecycleTesting)
        let stderr = CLIPipeReader(handle: error.fileHandleForReading, limit: stderrLimit,
                                channel: .stderr, lifecycleTesting: lifecycleTesting)
        self.stdout = stdout
        self.stderr = stderr
        await stdout.start(on: ioQueue, executor: ioExecutor) { [self] in Task(executorPreference: controlExecutor) {
            await self.notifyOutputExceeded()
        } }
        if let suspension = lifecycleTesting?.suspension {
            await suspension(.afterStdoutInstalled)
        }
        // Cancellation and an early reader overflow can race this suspension.
        // A terminating launch must never install more readers or replace its
        // already-owned kill timer with a new running timeout.
        guard phase == .launching, !cancellationRequested else { return }
        await stderr.start(on: ioQueue, executor: ioExecutor) { [self] in
            Task(executorPreference: controlExecutor) {
                await self.notifyOutputExceeded()
            }
        }
        guard phase == .launching, !cancellationRequested else { return }
        phase = .running
        lifecycleTesting?.marker(.running)
        scheduleTimeoutTermination()
        if exitedDuringLaunch { await processDidExit() }
    }

    private func prepareProcess() -> (Process, Pipe, Pipe) {
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
        return (process, output, error)
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
        let executor = controlExecutor
        timer.setEventHandler { [weak self] in
            Task(executorPreference: executor) {
                await self?.beginTermination(reason: .timeout)
            }
        }
        timeoutTimer = timer
        timer.resume()
    }

    // Keep the reader notification suspension on its calling control task,
    // before entering the execution actor for overflow handling.
    nonisolated private func notifyOutputExceeded() async {
        if let suspension = lifecycleTesting?.suspension { await suspension(.beforeOutputLimitNotification) }
        await outputExceeded()
        lifecycleTesting?.marker(.outputLimitNotificationCompleted)
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
        let executor = controlExecutor
        killTimer.setEventHandler { [weak self] in
            Task(executorPreference: executor) {
                await self?.killIfStillOwned()
            }
        }
        timeoutTimer = killTimer
        killTimer.resume()
    }

    private func killIfStillOwned() {
        // A timer can enqueue after the child is reaped but before the exit
        // task enters this actor. Both observed exit and Foundation's live
        // process state are required before signalling the owned PID.
        guard phase == .terminating, !observedExit, let process, process.isRunning else { return }
        lifecycleTesting?.marker(.forceKillAttempted)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func processDidExit() async {
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

}

private extension CLIExecution {
    private func finalizeExitedProcess() async {
        guard phase != .completed else { return }
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
        do { await complete(.success(try CLIRunner.result(for: process, stdout: output, stderr: error))) } catch { await complete(.failure(error)) }
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
