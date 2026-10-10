import Darwin
import Foundation
import os

/// One-shot entry observation for native reader-route tests.
nonisolated private final class CLIPipeReaderObservation: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: false)
    private let marker: @Sendable (CLIRunner.LifecycleTesting.Event) -> Void

    init(marker: @escaping @Sendable (CLIRunner.LifecycleTesting.Event) -> Void) {
        self.marker = marker
    }

    func recordFirstDrain() {
        let first = recorded.withLock { recorded in
            guard !recorded else { return false }
            recorded = true
            return true
        }
        if first { marker(.stderrDrainEntered) }
    }
}

/// Selects execution placement, not actor isolation or a real-time guarantee.
/// Tasks retain this operation-owned executor; each enqueued job also retains
/// it until that job has run. No synchronous queue waits or shutdown barriers.
nonisolated final class CLIRunnerTaskExecutor: TaskExecutor, Sendable {
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
            if let previous { dictionary[key] = previous } else { dictionary.removeObject(forKey: key) }
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

actor CLIPipeReader {
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
        // Reader-route tests distinguish stderr entry from stdout work.
        observation = channel == .stderr ? lifecycleTesting.map { CLIPipeReaderObservation(marker: $0.marker) } : nil
    }

    func start(on queue: DispatchQueue, executor: CLIRunnerTaskExecutor, onOverflow: @escaping @Sendable () -> Void) {
        self.onOverflow = onOverflow
        if readerCallbackRead != nil { callbackExecutorForTesting = executor }
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        let sourceRoute = CLIRunner.LifecycleTesting.ReaderRoute(channel: channel, callback: .readSource)
        let pollerRoute = CLIRunner.LifecycleTesting.ReaderRoute(channel: channel, callback: .poller)
        let enableSource = readerRouteUnderTest.map { $0 == sourceRoute } ?? true
        let enablePoller = readerRouteUnderTest.map { $0 == pollerRoute } ?? true
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard enableSource else { return }
            Task(executorPreference: executor) { await self?.drain(callback: .readSource) }
        }
        source.setCancelHandler { [handle] in try? handle.close() }
        self.source = source
        source.resume()
        let poller = DispatchSource.makeTimerSource(queue: queue)
        poller.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        poller.setEventHandler { [weak self] in
            guard enablePoller else { return }
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
        observation?.recordFirstDrain()
        guard !discarded else { return }
        for index in 0..<8 {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                if let callback, let readerCallbackRead, !didReportCallbackRead {
                    didReportCallbackRead = true
                    readerCallbackRead(.init(channel: channel, callback: callback), inOwnedIOJob)
                }
                let chunk = Data(bytes.prefix(Int(count)))
                if let limit, data.count > limit - chunk.count {
                    overflowed = true
                    discarded = true
                    CLIRunner.zero(&data)
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
