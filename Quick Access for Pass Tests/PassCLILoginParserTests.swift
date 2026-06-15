import Testing
import Foundation
@testable import Quick_Access_for_Pass

struct PassCLILoginParserTests {
    private let syntheticURL = "https://account.proton.me/desktop/login?app=pass#payload=synthetic-test-payload"

    @Test func extractsSyntheticProtonLoginURLFromCLIOutput() throws {
        let output = """
        Please open the following URL in your browser to complete authentication:

        \(syntheticURL)

        Waiting for authentication to complete...
        """

        let url = try #require(PassCLILoginParser.authenticationURL(in: output))

        #expect(url.scheme == "https")
        #expect(url.host == "account.proton.me")
        #expect(url.path == "/desktop/login")
        #expect(url.query?.contains("app=pass") == true)
        #expect(url.fragment == "payload=synthetic-test-payload")
    }

    @Test(arguments: [
        "https://example.com/desktop/login?app=pass#payload=x",
        "http://account.proton.me/desktop/login?app=pass#payload=x",
        "https://account.proton.me/desktop/login?app=other#payload=x",
        "https://account.proton.me/desktop/login?app=pass",
        "https://user:pass@account.proton.me/desktop/login?app=pass#payload=x",
    ])
    func rejectsInvalidLoginURLs(candidate: String) {
        #expect(PassCLILoginParser.authenticationURL(in: candidate) == nil)
    }

    @Test func stripsAnsiEscapesBeforeParsing() throws {
        let output = "\u{001B}[32m\(syntheticURL)\u{001B}[0m"
        let url = try #require(PassCLILoginParser.authenticationURL(in: output))
        #expect(url.fragment == "payload=synthetic-test-payload")
    }

    @Test func sanitizerRedactsLoginURLsAndTruncatesLongOutput() {
        let output = String(repeating: "x", count: 140) + " \(syntheticURL)"
        let sanitized = PassCLILoginParser.sanitizedMessage(from: output, limit: 80)

        #expect(sanitized.contains("payload=") == false)
        #expect(sanitized.contains("[Proton login URL redacted]") == true)
        #expect(sanitized.count <= 83)
    }
}
