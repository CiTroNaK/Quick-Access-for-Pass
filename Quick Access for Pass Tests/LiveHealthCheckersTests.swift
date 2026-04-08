// Quick Access for Pass Tests/LiveHealthCheckersTests.swift
import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("LiveHealthCheckers — smoke")
struct LiveHealthCheckersTests {

    private struct FakeRunner: CLIRunning {
        let behavior: @Sendable (_ args: [String]) async throws -> Data
        func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
            try await behavior(arguments)
        }
    }

    @Test("LivePassCLIHealthChecker returns .ok outcome when runner succeeds")
    func liveCLIHealthCheckerForwardsSuccess() async {
        let runner = FakeRunner { _ in Data() }
        let checker = LivePassCLIHealthChecker(runner: runner)
        let outcome = await checker.check(cliPath: "/fake")
        #expect(outcome.health == .ok)
    }

    @Test("LivePassCLIHealthChecker propagates notLoggedIn without fetching identity")
    func liveCLIHealthCheckerShortCircuitsOnFailure() async {
        let runner = FakeRunner { _ in throw CLIError.notLoggedIn }
        let checker = LivePassCLIHealthChecker(runner: runner)
        let outcome = await checker.check(cliPath: "/fake")
        #expect(outcome.health == .notLoggedIn)
        #expect(outcome.identity == nil)
        #expect(outcome.version == nil)
    }

    @Test("LiveRunProbeChecker returns unreachable on a missing socket")
    func liveRunProbeCheckerForwardsUnreachable() async {
        let checker = LiveRunProbeChecker()
        let result = await checker.check(socketPath: "/nonexistent/run-probe-smoke.sock")
        #expect({
            if case .unreachable = result { return true }
            return false
        }())
    }

    @Test("LiveSSHProbeChecker returns unreachable on a missing socket")
    func liveSSHProbeCheckerForwardsUnreachable() async {
        let checker = LiveSSHProbeChecker()
        let result = await checker.check(listenPath: "/nonexistent/ssh-probe-smoke.sock")
        #expect({
            if case .unreachable = result { return true }
            return false
        }())
    }
}
