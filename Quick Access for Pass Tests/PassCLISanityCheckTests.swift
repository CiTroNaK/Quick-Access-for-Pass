import Foundation
import Testing
@testable import Quick_Access_for_Pass

struct PassCLISanityCheckTests {
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

    @Test func returnsOkAndIdentityWhenInfoSucceeds() async {
        let runner = FakeRunner { args in
            #expect(args == ["info", "--output", "json"])
            return Data("""
            {
              "release_track": "stable",
              "username": "johndoe",
              "email": "john@example.com"
            }
            """.utf8)
        }

        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        #expect(outcome.health == .ok)
        #expect(outcome.identity?.username == "johndoe")
        #expect(outcome.identity?.email == "john@example.com")
    }

    @Test func successfulMalformedInfoKeepsHealthOkWithoutIdentity() async {
        let runner = FakeRunner { args in
            #expect(args == ["info", "--output", "json"])
            return Data("john@example.com is not JSON".utf8)
        }

        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        #expect(outcome.health == .ok)
        #expect(outcome.identity == nil)
    }

    @Test func returnsNotLoggedInOnNotLoggedInError() async {
        let runner = FakeRunner { _ in throw CLIError.notLoggedIn }
        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        #expect(outcome.health == .notLoggedIn)
        #expect(outcome.identity == nil)
    }

    @Test func returnsNotLoggedInOnAuthFailureMessage() async {
        let runner = FakeRunner { _ in
            throw CLIError.commandFailed("Error: not logged in. Run: pass-cli login")
        }
        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        #expect(outcome.health == .notLoggedIn)
        #expect(outcome.identity == nil)
    }

    @Test func genericErrorUsesOpaqueFailureReason() async {
        let runner = FakeRunner { _ in throw CLIError.commandFailed("disk full") }
        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        guard case .failed(let reason) = outcome.health else {
            Issue.record("Expected generic failure")
            return
        }
        #expect(reason.isEmpty == false)
        #expect(reason.contains("disk full") == false)
        #expect(outcome.identity == nil)
    }

    @Test func returnsFailedOnTimeout() async {
        let runner = FakeRunner { _ in throw CLIError.timeout }
        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        guard case .failed(let reason) = outcome.health else {
            Issue.record("Expected timeout failure")
            return
        }
        #expect(reason.contains("timed out"))
        #expect(outcome.identity == nil)
    }

    @Test func sensitiveCommandFailureDetailsNeverReachHealthReason() async {
        let sensitiveDetails = """
        {"username":"johndoe","email":"john@example.com","account_id":"account-secret"}
        https://example.com/login?token=token-secret
        """
        let runner = FakeRunner { _ in throw CLIError.commandFailed(sensitiveDetails) }
        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        guard case .failed(let reason) = outcome.health else {
            Issue.record("Expected opaque failure")
            return
        }
        for sensitiveValue in [
            "johndoe",
            "john@example.com",
            "account-secret",
            "token-secret",
            "example.com"
        ] {
            #expect(reason.contains(sensitiveValue) == false)
        }
        #expect(outcome.identity == nil)
    }

    @Test func returnsNotInstalledWhenBinaryMissing() async {
        let runner = FakeRunner { _ in throw CLIError.notInstalled }
        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        #expect(outcome.health == .notInstalled)
        #expect(outcome.identity == nil)
    }
}
