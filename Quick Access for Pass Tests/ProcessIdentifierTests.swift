import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("ProcessIdentifier Tests")
struct ProcessIdentifierTests {

    // MARK: - BatchMode Detection

    @Test("detects BatchMode=yes in command")
    func testBatchModeDetected() {
        #expect(ProcessIdentifier.isBatchModeCommand("ssh -T -o BatchMode=yes -o ConnectTimeout=2 git@github.com"))
    }

    @Test("detects BatchMode=yes case-insensitively")
    func testBatchModeCaseInsensitive() {
        #expect(ProcessIdentifier.isBatchModeCommand("ssh -o batchmode=yes git@github.com"))
    }

    @Test("no batch mode for regular SSH command")
    func testNoBatchMode() {
        #expect(ProcessIdentifier.isBatchModeCommand("ssh git@github.com") == false)
    }

    @Test("no batch mode for BatchMode=no")
    func testBatchModeNo() {
        #expect(ProcessIdentifier.isBatchModeCommand("ssh -o BatchMode=no git@github.com") == false)
    }

    @Test("no false positive for BatchMode in hostname")
    func testBatchModeNotInHostname() {
        #expect(ProcessIdentifier.isBatchModeCommand("ssh BatchMode=yes@example.com") == false)
    }

    @Test("detects concatenated -oBatchMode=yes")
    func testBatchModeConcatenated() {
        #expect(ProcessIdentifier.isBatchModeCommand("ssh -oBatchMode=yes git@github.com"))
    }

    // MARK: - Host Parsing

    @Test("parses user@host format")
    func testParseHostUserAt() {
        #expect(ProcessIdentifier.parseHost("ssh git@github.com") == "github.com")
    }

    @Test("parses bare host")
    func testParseHostBare() {
        #expect(ProcessIdentifier.parseHost("ssh example.com") == "example.com")
    }

    @Test("parses host after flags with values")
    func testParseHostAfterFlags() {
        #expect(ProcessIdentifier.parseHost("ssh -T -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=yes git@github.com") == "github.com")
    }

    @Test("parses host after -p port flag")
    func testParseHostAfterPort() {
        #expect(ProcessIdentifier.parseHost("ssh -p 2222 root@server.io") == "server.io")
    }

    @Test("returns nil for empty command")
    func testParseHostEmpty() {
        #expect(ProcessIdentifier.parseHost("ssh") == nil)
    }

    @Test("returns nil for flags-only command")
    func testParseHostFlagsOnly() {
        #expect(ProcessIdentifier.parseHost("ssh -T -v") == nil)
    }

    @Test("skips bare words without dots (e.g., TERM_PROGRAM)")
    func testParseHostSkipsBareWords() {
        #expect(ProcessIdentifier.parseHost("ssh TERM_PROGRAM git@github.com") == "github.com")
    }

    @Test("skips environment variable assignments before host")
    func testParseHostSkipsEnvVars() {
        #expect(ProcessIdentifier.parseHost("ssh COLORTERM=truecolor git@github.com") == "github.com")
    }

    @Test("parses host from Ghostty-style SSH command with multi-word -o values")
    func testParseHostGhosttyCommand() {
        let command = "ssh -o SetEnv COLORTERM=truecolor -o SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION -o ControlMaster=yes -o ControlPath=/tmp/ghostty-ssh-git.iDg7gN/socket -o ControlPersist=60s git@github.com"
        #expect(ProcessIdentifier.parseHost(command) == "github.com")
    }

    @Test("returns nil when no destination is found")
    func testParseHostNoDestination() {
        #expect(ProcessIdentifier.parseHost("ssh -T -v TERM_PROGRAM") == nil)
    }

    // MARK: - Destination Parsing

    @Test("parseDestination extracts ssh user@host from simple command")
    func testParseDestinationSimple() {
        #expect(ProcessIdentifier.parseDestination("ssh git@github.com") == "ssh git@github.com")
    }

    @Test("parseDestination extracts ssh host from bare host")
    func testParseDestinationBareHost() {
        #expect(ProcessIdentifier.parseDestination("ssh example.com") == "ssh example.com")
    }

    @Test("parseDestination strips Ghostty-injected options")
    func testParseDestinationGhostty() {
        let command = "ssh -o SetEnv COLORTERM=truecolor -o SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION -o ControlMaster=yes -o ControlPath=/tmp/ghostty-ssh-git.iDg7gN/socket -o ControlPersist=60s git@github.com"
        #expect(ProcessIdentifier.parseDestination(command) == "ssh git@github.com")
    }

    @Test("parseDestination returns nil for flags-only command")
    func testParseDestinationFlagsOnly() {
        #expect(ProcessIdentifier.parseDestination("ssh -T -v") == nil)
    }

    @Test("parseDestination handles port flag")
    func testParseDestinationWithPort() {
        #expect(ProcessIdentifier.parseDestination("ssh -p 2222 root@server.io") == "ssh root@server.io")
    }
}
