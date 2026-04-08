import Testing
import Foundation
@testable import Quick_Access_for_Pass

struct PassCLISanityCheckTests {

    private struct FakeRunner: CLIRunning {
        let behavior: @Sendable (_ args: [String]) async throws -> Data
        func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
            try await behavior(arguments)
        }
    }

    private actor ArgsCollector {
        var args: [String] = []
        func set(_ value: [String]) { args = value }
    }

    @Test func returnsOkWhenCommandSucceeds() async {
        let runner = FakeRunner { _ in Data("vault1\nvault2\n".utf8) }
        let result = await PassCLISanityCheck.checkLoginStatus(cliPath: "/fake/pass-cli", runner: runner)
        #expect(result == .ok)
    }

    @Test func returnsNotLoggedInOnNotLoggedInError() async {
        let runner = FakeRunner { _ in throw CLIError.notLoggedIn }
        let result = await PassCLISanityCheck.checkLoginStatus(cliPath: "/fake/pass-cli", runner: runner)
        #expect(result == .notLoggedIn)
    }

    @Test func returnsNotLoggedInOnAuthFailureMessage() async {
        let runner = FakeRunner { _ in
            throw CLIError.commandFailed("Error: not logged in. Run: pass-cli login")
        }
        let result = await PassCLISanityCheck.checkLoginStatus(cliPath: "/fake/pass-cli", runner: runner)
        #expect(result == .notLoggedIn)
    }

    @Test func returnsFailedOnGenericError() async {
        let runner = FakeRunner { _ in throw CLIError.commandFailed("disk full") }
        let result = await PassCLISanityCheck.checkLoginStatus(cliPath: "/fake/pass-cli", runner: runner)
        if case .failed(let reason) = result {
            #expect(reason.contains("disk full"))
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }

    @Test func usesTestCommand() async {
        let collector = ArgsCollector()
        let runner = FakeRunner { args in
            await collector.set(args)
            return Data()
        }
        _ = await PassCLISanityCheck.checkLoginStatus(cliPath: "/fake/pass-cli", runner: runner)
        let captured = await collector.args
        #expect(captured == ["test"])
    }

    @Test func returnsNotInstalledWhenBinaryMissing() async {
        let runner = FakeRunner { _ in throw CLIError.notInstalled }
        let result = await PassCLISanityCheck.checkLoginStatus(cliPath: "/fake/pass-cli", runner: runner)
        #expect(result == .notInstalled)
    }
}
