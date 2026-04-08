import Testing
import Foundation
import Darwin
@testable import Quick_Access_for_Pass

@MainActor
struct SSHAgentProxyFailureSignalTests {

    @Test func upstreamCloseFiresFailureSignal() async throws {
        // Writing to a socket whose peer has closed raises SIGPIPE by default,
        // which crashes the xctest process. Production app ignores it implicitly
        // via higher-level signal handling; the test harness does not.
        signal(SIGPIPE, SIG_IGN)

        let upstream = try FakeAgentListener(mode: .closeImmediately)
        let listenPath = NSTemporaryDirectory() + "ssh-proxy-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(listenPath) }

        let (stream, continuation) = AsyncStream<SSHClientLoopFailure>.makeStream(bufferingPolicy: .unbounded)

        let proxy = SSHAgentProxy(
            listenPath: listenPath,
            upstreamPath: upstream.socketPath,
            authorizationHandler: { _, _ in .allow },
            failureSignal: { failure in
                continuation.yield(failure)
            }
        )
        try await proxy.start()

        // Trigger runClientLoop via a probe connect
        _ = await SSHProxyProbe.listIdentities(at: listenPath, timeout: 0.5)

        // Deterministically await the first failure signal — no wall clock
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received != nil, "expected SSHClientLoopFailure from closed upstream")

        continuation.finish()
        await proxy.stop()
        await upstream.stop()
    }
}
