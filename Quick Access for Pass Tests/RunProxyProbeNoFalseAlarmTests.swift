import Testing
import Foundation
import Darwin
@testable import Quick_Access_for_Pass

/// Regression guard for the "Settings → Run shows upstream error while proxy
/// works" bug. Before the round-trip probe fix, calling `RunProxyProbe.ping`
/// against a real `RunProxy` would cause `handleClient` to fire
/// `.clientRequestReadFailed` because the probe only did a bare connect()
/// with no bytes. This test pings 5× in a row and asserts every call
/// returns `.healthy` — proving the probe no longer self-inflicts failures.
struct RunProxyProbeNoFalseAlarmTests {

    @Test("5 consecutive pings against a real RunProxy all return healthy")
    func fiveConsecutivePingsStayHealthy() async throws {
        let listenPath = NSTemporaryDirectory() + "run-noalarm-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(listenPath) }

        let proxy = RunProxy(
            listenPath: listenPath,
            authorizationHandler: { _, _ in
                Issue.record("auth handler must not run for ping")
                return RunProxyResponse(decision: .deny, env: nil)
            },
            failureSignal: { failure in
                Issue.record("unexpected failure signal: \(failure)")
            },
            verifier: { fd in VerifiedConnection(fd: fd, identity: .trustedHelper, pid: ProcessInfo.processInfo.processIdentifier) }
        )
        try await proxy.start()

        for iteration in 1...5 {
            let result = await RunProxyProbe.ping(at: listenPath)
            #expect(result == .healthy, "ping #\(iteration) was \(result)")
        }

        await proxy.stop()
    }
}
