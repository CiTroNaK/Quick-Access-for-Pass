// Quick Access for Pass Tests/LiveHealthCheckersTests.swift
import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("LiveHealthCheckers — smoke")
struct LiveHealthCheckersTests {
    private struct FakeRunner: CLIRunning {
        let behavior: @Sendable (_ args: [String]) async throws -> Data

        func run(
            executablePath: String,
            arguments: [String],
            timeout: TimeInterval
        ) async throws -> Data {
            try await behavior(arguments)
        }
    }

    private actor InvocationRecorder {
        private var invocations: [[String]] = []

        func record(_ arguments: [String]) {
            invocations.append(arguments)
        }

        func count(_ arguments: [String]) -> Int {
            invocations.count { $0 == arguments }
        }
    }

    @Test("LivePassCLIHealthChecker composes health, identity, and version with one info call")
    func liveCLIHealthCheckerComposesSuccessfulOutcome() async {
        let recorder = InvocationRecorder()
        let runner = FakeRunner { args in
            await recorder.record(args)
            switch args {
            case ["info", "--output", "json"]:
                return Data(#"{"username":"johndoe","email":"john@example.com"}"#.utf8)
            case ["--version"]:
                return Data("pass-cli 2.3.3\n".utf8)
            default:
                throw CLIError.commandFailed("unexpected arguments: \(args)")
            }
        }

        let outcome = await LivePassCLIHealthChecker(runner: runner).check(cliPath: "/fake")

        #expect(outcome.health == .ok)
        #expect(outcome.identity?.username == "johndoe")
        #expect(outcome.version == "2.3.3")
        #expect(await recorder.count(["info", "--output", "json"]) == 1)
    }

    @Test("LivePassCLIHealthChecker keeps version metadata when authentication fails")
    func liveCLIHealthCheckerKeepsVersionOnAuthenticationFailure() async {
        let runner = FakeRunner { args in
            if args == ["--version"] {
                return Data("pass-cli 2.3.3\n".utf8)
            }
            throw CLIError.notLoggedIn
        }

        let outcome = await LivePassCLIHealthChecker(runner: runner).check(cliPath: "/fake")

        #expect(outcome.health == .notLoggedIn)
        #expect(outcome.identity == nil)
        #expect(outcome.version == "2.3.3")
    }

    @Test("LivePassCLIHealthChecker does not downgrade health when version fails")
    func liveCLIHealthCheckerKeepsAuthenticatedHealthWhenVersionFails() async {
        let runner = FakeRunner { args in
            if args == ["--version"] {
                throw CLIError.commandFailed("version unavailable")
            }
            return Data(#"{"username":"johndoe"}"#.utf8)
        }

        let outcome = await LivePassCLIHealthChecker(runner: runner).check(cliPath: "/fake")

        #expect(outcome.health == .ok)
        #expect(outcome.identity?.username == "johndoe")
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
