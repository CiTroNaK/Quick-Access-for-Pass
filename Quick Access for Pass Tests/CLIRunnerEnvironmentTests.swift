import Foundation
import Testing
@testable import Quick_Access_for_Pass

struct CLIRunnerEnvironmentTests {
    @Test(.timeLimit(.minutes(1)))
    func runPassesEnvironmentOverridesToChildProcess() async throws {
        let script = """
        import os
        print(os.environ.get("PROTON_PASS_PERSONAL_ACCESS_TOKEN", "missing"))
        """

        let data = try await CLIRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: ["-c", script],
            environmentOverrides: ["PROTON_PASS_PERSONAL_ACCESS_TOKEN": "pst_test_token::secret"],
            timeout: 5
        )

        let output = try #require(String(bytes: data, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "pst_test_token::secret")
    }

    @Test(.timeLimit(.minutes(1)))
    func runKeepsExistingPathAugmentationWhenEnvironmentOverridesAreUsed() async throws {
        let script = """
        import os
        print(os.environ.get("PATH", ""))
        """

        let data = try await CLIRunner.run(
            executablePath: "/usr/bin/python3",
            arguments: ["-c", script],
            environmentOverrides: ["PROTON_PASS_PERSONAL_ACCESS_TOKEN": "pst_test_token::secret"],
            timeout: 5
        )

        let path = try #require(String(bytes: data, encoding: .utf8))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
    }
}
