import Foundation
import Testing
@testable import Quick_Access_for_Pass

struct PassCLISanityCheckIdentityTests {
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

    // MARK: Authenticated health identity

    @Test func authenticatedHealthDecodesValidIdentityJSON() async {
        let json = """
        {
          "release_track": "stable",
          "id": "AU4rjZ1nIGTPtLJRBXjQY2dei0zKq0NTAZ2c0Lclv7Q7rA9MqR6gflD2VT182QF6D3LFQMOgRiYikA8YpB0O1w==",
          "username": "johndoe",
          "email": "john@example.com"
        }
        """
        let runner = FakeRunner { args in
            #expect(args == ["info", "--output", "json"])
            return Data(json.utf8)
        }

        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )
        let identity = outcome.identity

        #expect(outcome.health == .ok)
        #expect(identity?.username == "johndoe")
        #expect(identity?.email == "john@example.com")
        #expect(identity?.releaseTrack == "stable")
        #expect(identity?.personalAccessTokenName == nil)
        #expect(identity?.displayName == "johndoe")
        #expect(identity?.isPersonalAccessTokenSession == false)
    }

    @Test func authenticatedHealthDecodesPATOnlyIdentityJSON() async {
        let json = """
        {
          "username": "Personal Access Token"
        }
        """
        let runner = FakeRunner { args in
            #expect(args == ["info", "--output", "json"])
            return Data(json.utf8)
        }

        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )
        let identity = outcome.identity

        #expect(outcome.health == .ok)
        #expect(identity?.username == "Personal Access Token")
        #expect(identity?.email == nil)
        #expect(identity?.releaseTrack == nil)
        #expect(identity?.personalAccessTokenName == nil)
        #expect(identity?.displayName == "Personal Access Token")
    }

    @Test func authenticatedHealthDecodesPATNameJSON() async {
        let json = """
        {
          "release_track": "stable",
          "id": "N/A",
          "personal_access_token_name": "Quick Access for Pass"
        }
        """
        let runner = FakeRunner { args in
            #expect(args == ["info", "--output", "json"])
            return Data(json.utf8)
        }

        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )
        let identity = outcome.identity

        #expect(outcome.health == .ok)
        #expect(identity?.username == nil)
        #expect(identity?.email == nil)
        #expect(identity?.releaseTrack == "stable")
        #expect(identity?.personalAccessTokenName == "Quick Access for Pass")
        #expect(identity?.displayName == "Quick Access for Pass")
        #expect(identity?.isPersonalAccessTokenSession == true)
    }

    @Test func authenticatedHealthKeepsOkStatusOnInvalidJSON() async {
        let runner = FakeRunner { _ in Data("not json".utf8) }
        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        #expect(outcome.health == .ok)
        #expect(outcome.identity == nil)
    }

    @Test func authenticatedHealthReturnsNotInstalledOnRunnerError() async {
        let runner = FakeRunner { _ in throw CLIError.notInstalled }
        let outcome = await PassCLISanityCheck.checkAuthenticatedHealth(
            cliPath: "/fake/pass-cli",
            runner: runner
        )

        #expect(outcome.health == .notInstalled)
        #expect(outcome.identity == nil)
    }

    // MARK: Version

    @Test func fetchVersionStripsPrefixAndWhitespace() async {
        let runner = FakeRunner { args in
            #expect(args == ["--version"])
            return Data("pass-cli 1.4.2\n".utf8)
        }
        let version = await PassCLISanityCheck.fetchVersion(cliPath: "/fake/pass-cli", runner: runner)
        #expect(version == "1.4.2")
    }

    @Test func fetchVersionReturnsRawWhenNoPrefix() async {
        let runner = FakeRunner { _ in Data("1.4.2\n".utf8) }
        let version = await PassCLISanityCheck.fetchVersion(cliPath: "/fake/pass-cli", runner: runner)
        #expect(version == "1.4.2")
    }

    @Test func fetchVersionReturnsNilOnRunnerError() async {
        let runner = FakeRunner { _ in throw CLIError.commandFailed("boom") }
        let version = await PassCLISanityCheck.fetchVersion(cliPath: "/fake/pass-cli", runner: runner)
        #expect(version == nil)
    }
}
