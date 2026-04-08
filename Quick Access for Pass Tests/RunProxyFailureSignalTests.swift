import Testing
import Foundation
import Darwin
@testable import Quick_Access_for_Pass

nonisolated struct RunProxyFailureSignalTests {

    @Test("clientRequestReadFailed is not treated as a health-affecting failure")
    func clientRequestReadFailedIsNotHealthAffecting() {
        #expect(RunProxyCoordinator.shouldSignalHealth(for: .clientRequestReadFailed) == false)
    }

    @Test("authHandlerTimedOut is treated as a health-affecting failure")
    func authHandlerTimedOutIsHealthAffecting() {
        #expect(RunProxyCoordinator.shouldSignalHealth(for: .authHandlerTimedOut) == true)
    }

    @Test("clientResponseWriteFailed is treated as a health-affecting failure")
    func clientResponseWriteFailedIsHealthAffecting() {
        #expect(RunProxyCoordinator.shouldSignalHealth(for: .clientResponseWriteFailed) == true)
    }

    @Test func requestReadFailureFiresSignal() async throws {
        let listenPath = NSTemporaryDirectory() + "run-proxy-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(listenPath) }

        let (stream, continuation) = AsyncStream<RunClientLoopFailure>.makeStream(bufferingPolicy: .unbounded)

        let proxy = RunProxy(
            listenPath: listenPath,
            authorizationHandler: { _, _ in RunProxyResponse(decision: .deny, env: nil) },
            failureSignal: { failure in
                continuation.yield(failure)
            },
            verifier: { fd in VerifiedConnection(fd: fd, identity: .trustedHelper, pid: ProcessInfo.processInfo.processIdentifier) }
        )
        try await proxy.start()

        // Connect and close without sending a valid RunProxyRequest
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = SSHAgentConstants.makeUnixAddr(path: listenPath)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)  // immediate close — request read on server side will fail

        // Deterministically await the first failure signal — no wall clock
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received != nil, "expected RunClientLoopFailure from client close before request")

        continuation.finish()
        await proxy.stop()
    }
}
