import Testing
import Foundation
import Darwin
@testable import Quick_Access_for_Pass

struct RunProxyProbeTests {

    @Test("probe returns .unreachable(.connectFailed) when no listener")
    func returnsUnreachableWhenNoListener() async {
        let path = NSTemporaryDirectory() + "no-run-\(UUID().uuidString.prefix(8)).sock"
        let result = await RunProxyProbe.ping(at: path)
        guard case .unreachable(.connectFailed) = result else {
            Issue.record("expected .unreachable(.connectFailed), got \(result)")
            return
        }
    }

    @Test("probe round-trips against a real RunProxy")
    func roundTripAgainstRealRunProxy() async throws {
        let listenPath = NSTemporaryDirectory() + "run-probe-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(listenPath) }

        let proxy = RunProxy(
            listenPath: listenPath,
            authorizationHandler: { _, _ in
                Issue.record("auth handler must not run for ping")
                return RunProxyResponse(decision: .deny, env: nil)
            },
            failureSignal: { _ in },
            verifier: { fd in VerifiedConnection(fd: fd, identity: .trustedHelper, pid: ProcessInfo.processInfo.processIdentifier) }
        )
        try await proxy.start()

        let result = await RunProxyProbe.ping(at: listenPath)
        #expect(result == .healthy)

        await proxy.stop()
    }

    @Test("probe returns .unreachable when listener accepts and closes without replying")
    func returnsUnreachableWhenListenerDropsRoundTrip() async throws {
        let listener = try FakeAgentListener(mode: .acceptAndClose)
        let result = await RunProxyProbe.ping(at: listener.socketPath)
        await listener.stop()
        guard case .unreachable = result else {
            Issue.record("expected .unreachable, got \(result)")
            return
        }
    }
}
