import Testing
@testable import Quick_Access_for_Pass

struct CLIRunnerAuthClassificationTests {
    @Test(arguments: [
        "Error: not logged in",
        "ERROR: Not Logged In to Pass",
        "please log in first",
        "Pass-cli: not logged in.",
        // Pass-cli 2.x: the ERROR line from pass-cli/src/main.rs:301 when any non-logout
        // command is run while there is no active session.
        "2026-04-14T16:54:24.023444Z ERROR pass-cli/src/main.rs:301: Command is not logout there is no session",
        "command is not logout there is no session",
        "Error: Error listing vaults\nCaused by:\n    0: Error listing shares\n    1: Error sending request\n    2: failed to authenticate: non-existent session\n    3: non-existent session",
        "Error: FAILED TO AUTHENTICATE: NON-EXISTENT SESSION",
    ])
    func classifiesLoggedOutPhrases(stderr: String) {
        #expect(CLIRunner.stderrIndicatesNotLoggedIn(stderr) == true,
                "should classify \(stderr) as not-logged-in")
    }

    @Test(arguments: [
        "",
        "vault not found",
        "sync failed: session expired during fetch",
        "session expired during sync",   // ← historical false positive, must stay false
        "author unavailable",
        "auth provider: github",
        "network unreachable",
        "Error: Already authenticated",
        "could not open non-existent session file",
    ])
    func doesNotClassifyUnrelatedErrors(stderr: String) {
        #expect(CLIRunner.stderrIndicatesNotLoggedIn(stderr) == false,
                "should NOT classify \(stderr) as not-logged-in")
    }

    @Test(arguments: [
        "sync failed: session expired during fetch",
        "author unavailable",
        "auth provider: github",
    ])
    func cliErrorIsAuthErrorRejectsLookAlikes(stderr: String) {
        let error = CLIError.commandFailed(stderr)
        #expect(error.isAuthError == false,
                "CLIError.commandFailed(\(stderr)).isAuthError should be false")
    }

    @Test(arguments: [
        "Error: not logged in",
        "ERROR: Not Logged In to Pass",
        "please log in first",
        "Error getting personal access token name: failed to authenticate: non-existent session",
        "2026-04-14T16:54:24Z ERROR pass-cli/src/main.rs:301: Command is not logout there is no session",
    ])
    func cliErrorIsAuthErrorAcceptsRealPhrases(stderr: String) {
        let error = CLIError.commandFailed(stderr)
        #expect(error.isAuthError == true,
                "CLIError.commandFailed(\(stderr)).isAuthError should be true")
    }

    @Test func cliErrorNotLoggedInIsAlwaysAuthError() {
        #expect(CLIError.notLoggedIn.isAuthError == true)
    }
}
