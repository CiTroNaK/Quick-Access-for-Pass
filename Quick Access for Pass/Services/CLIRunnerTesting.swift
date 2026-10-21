import Foundation

nonisolated struct CLIRunnerLifecycleTesting: Sendable {
    nonisolated enum Event: Sendable {
        case deadlineCaptured, startTaskEntered
        case launching, running, terminating, finalizationOwned, completed
        case outputLimitNotificationCompleted, outputExceededEntered
        case stderrDrainEntered
        case nativeExitCallbackEntered, nativeExitTaskEntered, forceKillAttempted
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
