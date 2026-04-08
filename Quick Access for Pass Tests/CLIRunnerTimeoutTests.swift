import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("CLIRunner timeout")
struct CLIRunnerTimeoutTests {

    /// Exercises `CLIRunner.run`'s timeout path with a real `/bin/sleep 60`
    /// subprocess and a 1-second timeout. The `.timeLimit(.minutes(1))`
    /// trait ensures that if the timeout handling is genuinely broken and
    /// the call hangs waiting for the 60-second sleep, Swift Testing kills
    /// the test after 1 minute instead of blocking the entire suite.
    @Test(
        "run() throws .timeout when subprocess exceeds timeout",
        .timeLimit(.minutes(1))
    )
    func timeoutThrowsCLIErrorTimeout() async throws {
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await #expect {
                _ = try await CLIRunner.run(
                    executablePath: "/bin/sleep",
                    arguments: ["60"],
                    timeout: 1.0
                )
            } throws: { error in
                guard let e = error as? CLIError, case .timeout = e else { return false }
                return true
            }
        }

        #expect(elapsed < .seconds(5), "CLIRunner.run took \(elapsed), expected < 5s")
    }
}
