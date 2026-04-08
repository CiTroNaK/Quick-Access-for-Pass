import Testing
import Foundation
@testable import Quick_Access_for_Pass

struct SSHProxyProbeTests {

    @Test func returnsUnreachableWhenNoListener() async {
        let path = NSTemporaryDirectory() + "nonexistent-\(UUID().uuidString.prefix(8)).sock"
        let result = await SSHProxyProbe.listIdentities(at: path)
        guard case .unreachable(let failure) = result else {
            Issue.record("expected .unreachable, got \(result)")
            return
        }
        if case .connectFailed = failure { /* ok */ }
        else { Issue.record("expected .connectFailed, got \(failure)") }
    }

    @Test func returnsHealthyWhenListenerAnswersWithIdentities() async throws {
        let listener = try FakeAgentListener(mode: .respondWithIdentities([
            .init(keyBlob: Data([0x01, 0x02, 0x03]), comment: "user@host")
        ]))

        let result = await SSHProxyProbe.listIdentities(at: listener.socketPath)
        guard case .healthy(let count) = result else {
            Issue.record("expected .healthy, got \(result)")
            await listener.stop()
            return
        }
        #expect(count == 1)
        await listener.stop()
    }

    @Test func returnsEmptyIdentitiesWhenListenerAnswersWithNone() async throws {
        let listener = try FakeAgentListener(mode: .respondWithNoIdentities)

        let result = await SSHProxyProbe.listIdentities(at: listener.socketPath)
        #expect(result == .emptyIdentities)
        await listener.stop()
    }

    @Test func returnsUnreachableOnTimeout() async throws {
        let listener = try FakeAgentListener(mode: .neverRespond)

        let result = await SSHProxyProbe.listIdentities(at: listener.socketPath, timeout: 0.15)
        guard case .unreachable = result else {
            Issue.record("expected .unreachable after timeout, got \(result)")
            await listener.stop()
            return
        }
        await listener.stop()
    }

    @Test func returnsParseFailedOnGarbageResponse() async throws {
        let listener = try FakeAgentListener(mode: .respondWithGarbage)
        let result = await SSHProxyProbe.listIdentities(at: listener.socketPath, timeout: 0.5)
        #expect(result == .unreachable(.parseFailed))
        await listener.stop()
    }

    @Test func returnsReadOrWriteFailedOnImmediateClose() async throws {
        // Writing to a socket whose peer has closed raises SIGPIPE by default,
        // which would kill the test process. Ignore it so the probe sees EPIPE.
        signal(SIGPIPE, SIG_IGN)

        let listener = try FakeAgentListener(mode: .closeImmediately)
        let result = await SSHProxyProbe.listIdentities(at: listener.socketPath, timeout: 0.5)
        if case .unreachable(.readFailed) = result {
            // expected path
        } else if case .unreachable(.writeFailed) = result {
            // also acceptable — kernel may accept the write into a closed socket buffer
        } else {
            Issue.record("expected .readFailed or .writeFailed, got \(result)")
        }
        await listener.stop()
    }
}
