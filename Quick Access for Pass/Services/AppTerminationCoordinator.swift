import AppKit

/// Owns the asynchronous part of application termination without retaining
/// unowned cleanup work. AppDelegate remains the composition root.
@MainActor
final class AppTerminationCoordinator {
    private enum State {
        case idle
        case stopping
        case finished
    }

    private let cancelStartup: @MainActor @Sendable () -> Void
    private let cancelBrokerStart: @MainActor @Sendable () -> Void
    private let awaitStartup: @MainActor @Sendable () async -> Void
    private let awaitBrokerStart: @MainActor @Sendable () async -> Void
    private let stopOfflineWork: @MainActor @Sendable () async -> Void
    private let stopMaintenance: @MainActor @Sendable () async -> Void
    private let stopBroker: @MainActor @Sendable () async -> Void
    private let reply: @MainActor @Sendable () -> Void
    private var state: State = .idle
    private var terminationTask: Task<Void, Never>?

    init(
        cancelStartup: @escaping @MainActor @Sendable () -> Void,
        cancelBrokerStart: @escaping @MainActor @Sendable () -> Void,
        awaitStartup: @escaping @MainActor @Sendable () async -> Void,
        awaitBrokerStart: @escaping @MainActor @Sendable () async -> Void,
        stopOfflineWork: @escaping @MainActor @Sendable () async -> Void = {},
        stopMaintenance: @escaping @MainActor @Sendable () async -> Void,
        stopBroker: @escaping @MainActor @Sendable () async -> Void,
        reply: @escaping @MainActor @Sendable () -> Void
    ) {
        self.cancelStartup = cancelStartup
        self.cancelBrokerStart = cancelBrokerStart
        self.awaitStartup = awaitStartup
        self.awaitBrokerStart = awaitBrokerStart
        self.stopOfflineWork = stopOfflineWork
        self.stopMaintenance = stopMaintenance
        self.stopBroker = stopBroker
        self.reply = reply
    }

    convenience init() {
        self.init(
            cancelStartup: {},
            cancelBrokerStart: {},
            awaitStartup: {},
            awaitBrokerStart: {},
            stopOfflineWork: {},
            stopMaintenance: {},
            stopBroker: {},
            reply: {}
        )
    }

    func beginTermination() -> NSApplication.TerminateReply {
        switch state {
        case .finished:
            return .terminateNow
        case .stopping:
            return .terminateLater
        case .idle:
            state = .stopping
            cancelStartup()
            cancelBrokerStart()
            terminationTask = Task { [weak self] in
                await self?.finishTermination()
            }
            return .terminateLater
        }
    }

    private func finishTermination() async {
        await awaitStartup()
        await stopOfflineWork()
        await stopMaintenance()
        await awaitBrokerStart()
        await stopBroker()
        state = .finished
        terminationTask = nil
        reply()
    }
}
