import AppKit
import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("App termination coordinator", .timeLimit(.minutes(1)))
@MainActor
struct AppTerminationCoordinatorTests {
    @Test func joinsLiveStartupMaintenanceAndBrokerBeforeOneReply() async throws {
        let startupGate = OfflineTestGate()
        let trace = TerminationTrace()
        let coordinator = AppTerminationCoordinator(
            cancelStartup: { trace.events.append("cancelStartup") },
            cancelBrokerStart: { trace.events.append("cancelBrokerStart") },
            awaitStartup: {
                trace.events.append("awaitStartup")
                try? await startupGate.wait()
            },
            awaitBrokerStart: { trace.events.append("awaitBrokerStart") },
            stopOfflineWork: { trace.events.append("stopOfflineWork") },
            stopMaintenance: { trace.events.append("stopMaintenance") },
            stopBroker: { trace.events.append("stopBroker") },
            reply: { trace.replyCount += 1 }
        )

        #expect(coordinator.beginTermination() == .terminateLater)
        #expect(coordinator.beginTermination() == .terminateLater)
        try await startupGate.waitUntilEntered()
        #expect(trace.events == ["cancelStartup", "cancelBrokerStart", "awaitStartup"])

        await startupGate.open()
        for _ in 0..<100 where trace.replyCount == 0 { await Task.yield() }

        #expect(trace.events == [
            "cancelStartup", "cancelBrokerStart", "awaitStartup", "stopOfflineWork", "stopMaintenance", "awaitBrokerStart", "stopBroker"
        ])
        #expect(trace.replyCount == 1)
        #expect(coordinator.beginTermination() == .terminateNow)
        #expect(trace.replyCount == 1)
    }

    @Test func waitsForBrokerStartBeforeStoppingBrokerAndReplying() async throws {
        let startupGate = OfflineTestGate()
        let brokerStartGate = OfflineTestGate()
        let trace = TerminationTrace()
        let coordinator = AppTerminationCoordinator(
            cancelStartup: { trace.events.append("cancelStartup") },
            cancelBrokerStart: { trace.events.append("cancelBrokerStart") },
            awaitStartup: {
                trace.events.append("awaitStartup")
                try? await startupGate.wait()
            },
            awaitBrokerStart: {
                trace.events.append("awaitBrokerStart")
                try? await brokerStartGate.wait()
            },
            stopOfflineWork: { trace.events.append("stopOfflineWork") },
            stopMaintenance: { trace.events.append("stopMaintenance") },
            stopBroker: { trace.events.append("stopBroker") },
            reply: { trace.replyCount += 1 }
        )

        #expect(coordinator.beginTermination() == .terminateLater)
        try await startupGate.waitUntilEntered()
        await startupGate.open()
        for _ in 0..<100 where !trace.events.contains("awaitBrokerStart") { await Task.yield() }
        #expect(trace.events == ["cancelStartup", "cancelBrokerStart", "awaitStartup", "stopOfflineWork", "stopMaintenance", "awaitBrokerStart"])
        #expect(trace.replyCount == 0)

        await brokerStartGate.open()
        for _ in 0..<100 where trace.replyCount == 0 { await Task.yield() }
        #expect(trace.events.last == "stopBroker")
        #expect(trace.replyCount == 1)
    }

    @Test func earlyQuitPermanentlyBlocksOldAndFreshSecretCapabilitiesAndUnlockAdmission() async throws {
        let startupGate = OfflineTestGate()
        let delegate = AppDelegate()
        let oldToken = delegate.secretReleaseGuard.capture()
        delegate.terminationCoordinator = AppTerminationCoordinator(
            cancelStartup: {},
            cancelBrokerStart: {},
            awaitStartup: { try? await startupGate.wait() },
            awaitBrokerStart: {},
            stopOfflineWork: {},
            stopMaintenance: {},
            stopBroker: {},
            reply: {}
        )

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        try await startupGate.waitUntilEntered()
        let freshToken = delegate.secretReleaseGuard.capture()
        delegate.secretReleaseGuard.revoke()
        #expect(!delegate.secretReleaseGuard.isCurrent(oldToken))
        #expect(!delegate.secretReleaseGuard.isCurrent(freshToken))
        #expect(delegate.beginPanelUnlock() == nil)
        #expect(await delegate.showPanelAndWaitForUnlock(timeoutSeconds: 0) == false)
        let previousAuthentication = delegate.lastAuthenticatedAt
        delegate.completePanelUnlock()
        delegate.resetAuthTimestamp()
        #expect(delegate.lastAuthenticatedAt == previousAuthentication)

        await startupGate.open()
        for _ in 0..<100 { await Task.yield() }
    }

    @Test func earlyQuitResolvesExistingUnlockWaitersAndLateCallbacksCannotUnlock() async throws {
        let timeoutGate = OfflineTestGate()
        let delegate = AppDelegate()
        delegate.waitForUnlockTimeout = { _ in try? await timeoutGate.wait() }
        let waiter = Task { @MainActor in
            await delegate.showPanelAndWaitForUnlock(timeoutSeconds: 30)
        }
        for _ in 0..<100 where delegate.pendingUnlockWaiters.isEmpty { await Task.yield() }
        guard !delegate.pendingUnlockWaiters.isEmpty else {
            await timeoutGate.open()
            _ = await waiter.value
            Issue.record("Expected a registered unlock waiter before termination.")
            return
        }
        delegate.terminationCoordinator = AppTerminationCoordinator(
            cancelStartup: {}, cancelBrokerStart: {}, awaitStartup: {}, awaitBrokerStart: {},
            stopOfflineWork: {}, stopMaintenance: {}, stopBroker: {}, reply: {}
        )

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        #expect(await waiter.value == false)
        #expect(delegate.pendingUnlockWaiters.isEmpty)
        let previousAuthentication = delegate.lastAuthenticatedAt
        delegate.completePanelUnlock()
        delegate.resetAuthTimestamp()
        #expect(delegate.lastAuthenticatedAt == previousAuthentication)
        await timeoutGate.open()
    }
}

@MainActor
private final class TerminationTrace {
    var events: [String] = []
    var replyCount = 0
}
