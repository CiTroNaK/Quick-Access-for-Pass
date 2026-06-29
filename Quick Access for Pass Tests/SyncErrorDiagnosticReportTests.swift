import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Sync error diagnostic reports")
struct SyncErrorDiagnosticReportTests {

    @Test("generic and login presentations use approved messages and actions")
    func presentationWording() {
        let generic = SyncErrorPresentation.genericFailure(diagnosticReport: "diagnostic")
        #expect(generic.visibleMessage == "Sorry, there was a sync error.")
        #expect(generic.action == .copyAndReport)
        #expect(generic.action.title == "Copy & Report")
        #expect(generic.diagnosticReport == "diagnostic")
        #expect(SyncErrorPresentation.copyAndReportHelpText.contains("yes@petr.codes"))

        let login = SyncErrorPresentation.loginRequired()
        #expect(login.visibleMessage == "Please log in to Proton Pass CLI.")
        #expect(login.action == .login)
        #expect(login.action.title == "Log In")
        #expect(login.diagnosticReport == nil)

        let invalidPAT = SyncErrorPresentation.invalidPAT(
            userFacingMessage: "Personal access token is invalid, expired, or deleted. Replace it in Settings → Pass CLI or log in normally."
        )
        #expect(invalidPAT.visibleMessage == "Personal access token is invalid, expired, or deleted. Replace it in Settings → Pass CLI or log in normally.")
        #expect(invalidPAT.action == .updatePAT)
        #expect(invalidPAT.action.title == "Update PAT")
        #expect(invalidPAT.diagnosticReport == nil)
    }

    @Test("sanitizer redacts known sensitive values")
    func sanitizerRedactsSensitiveValues() {
        let raw = """
        Login URL: https://account.proton.me/desktop/login?app=pass#payload=secret-payload
        Token: pst_abc123::secret-value
        Env: PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_env_secret
        Email: user@example.com
        Item: pass://share-id/item-id
        Path: /Users/alice/bin/pass-cli
        Other: keep this diagnostic text
        """

        let sanitized = SyncErrorDiagnosticReport.sanitize(raw)

        #expect(!sanitized.contains("secret-payload"))
        #expect(!sanitized.contains("pst_abc123"))
        #expect(!sanitized.contains("pst_env_secret"))
        #expect(!sanitized.contains("user@example.com"))
        #expect(!sanitized.contains("pass://share-id/item-id"))
        #expect(!sanitized.contains("/Users/alice"))
        #expect(sanitized.contains("[Proton login URL redacted]"))
        #expect(sanitized.contains("PROTON_PASS_PERSONAL_ACCESS_TOKEN=[redacted]"))
        #expect(sanitized.contains("[personal access token redacted]"))
        #expect(sanitized.contains("[email redacted]"))
        #expect(sanitized.contains("pass://[redacted]"))
        #expect(sanitized.contains("~/bin/pass-cli"))
        #expect(sanitized.contains("keep this diagnostic text"))
    }

    @Test("report includes useful sync context without leaking raw sensitive values")
    func reportIncludesContextAndSanitizesError() {
        let error = CLIError.commandFailed(
            "failed for user@example.com with PROTON_PASS_PERSONAL_ACCESS_TOKEN=pst_secret and pass://share/item"
        )
        let report = SyncErrorDiagnosticReport.make(
            error: error,
            cliSelection: .custom(path: "/Users/alice/bin/pass-cli"),
            operation: "test sync operation",
            date: Date(timeIntervalSince1970: 0)
        )

        #expect(report.contains("Quick Access for Pass Sync Diagnostic Report"))
        #expect(report.contains("Timestamp: 1970-01-01T00:00:00Z"))
        #expect(report.contains("CLI source: Custom: ~/bin/pass-cli"))
        #expect(report.contains("CLI path: ~/bin/pass-cli"))
        #expect(report.contains("Operation: test sync operation"))
        #expect(report.contains("CLIError.commandFailed"))
        #expect(!report.contains("user@example.com"))
        #expect(!report.contains("pst_secret"))
        #expect(!report.contains("pass://share/item"))
        #expect(!report.contains("/Users/alice"))
    }

    @Test("report includes skipped summaries and optional diagnostic file path")
    func reportIncludesSkippedSummariesAndFilePath() {
        let skipped = SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "share-3",
            itemIndex: 3,
            itemId: "item-3",
            codingPath: "items.Index 3.content",
            reason: "failed for user@example.com at /Users/alice/item"
        )
        let report = SyncErrorDiagnosticReport.make(
            error: CLIError.timeout,
            cliSelection: .system(path: "/opt/homebrew/bin/pass-cli"),
            skippedItems: [skipped],
            diagnosticFileURL: URL(fileURLWithPath: "/Users/alice/Library/Caches/SyncDiagnostics/report.txt"),
            date: Date(timeIntervalSince1970: 0)
        )

        #expect(report.contains("Skipped items (showing first 1 of 1):"))
        #expect(report.contains("share_id=share-3"))
        #expect(report.contains("item_id=item-3"))
        #expect(report.contains("Full skipped-item diagnostics file: ~/Library/Caches/SyncDiagnostics/report.txt"))
        #expect(!report.contains("user@example.com"))
        #expect(!report.contains("/Users/alice"))
    }

    @Test("skipped item presentation sanitizes visible summaries")
    func skippedItemPresentationSanitizesVisibleSummaries() throws {
        let skipped = SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "share-7",
            itemIndex: 7,
            itemId: "item-7",
            codingPath: "items.Index 7.content",
            reason: "failed for user@example.com at /Users/alice/item with pass://share/item"
        )
        let presentation = try #require(SyncSkippedItemsPresentation.make(
            skippedItems: [skipped],
            diagnosticFileURL: nil
        ))

        let summary = try #require(presentation.visibleSummaries.first)
        #expect(summary.contains("share_id=share-7"))
        #expect(summary.contains("item_id=item-7"))
        #expect(!summary.contains("user@example.com"))
        #expect(!summary.contains("/Users/alice"))
        #expect(!summary.contains("pass://share/item"))
    }

    @Test("skipped item inspect command uses exact CLI path and stable share ID")
    func skippedItemInspectCommandUsesExactCLIPathAndStableShareID() {
        let skipped = SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "share with spaces",
            itemIndex: 7,
            itemId: "item-7",
            codingPath: "items.Index 7.content",
            reason: "expected String"
        )

        let command = skipped.inspectCommand(cliSelection: .bundled(
            path: "/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64",
            architecture: .arm64
        ))

        #expect(command == "'/Applications/Quick Access for Pass.app/Contents/Helpers/pass-cli-arm64' item view --share-id='share with spaces' --item-id=item-7 --output json")
    }

    @Test("skipped item inspect command binds hyphen-prefixed IDs as option values")
    func skippedItemInspectCommandBindsHyphenPrefixedIDsAsOptionValues() {
        let skipped = SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "-U0ojjze9edasueOpK0ll7llD2mIXKdS4cfL5DGhXSRm8f9soW9qKkhiXXXXXXX==",
            itemIndex: 7,
            itemId: "-item-7",
            codingPath: "items.Index 7.content",
            reason: "expected String"
        )

        let command = skipped.inspectCommand(cliSelection: .system(path: "/opt/homebrew/bin/pass-cli"))

        #expect(command == "/opt/homebrew/bin/pass-cli item view --share-id=-U0ojjze9edasueOpK0ll7llD2mIXKdS4cfL5DGhXSRm8f9soW9qKkhiXXXXXXX== --item-id=-item-7 --output json")
    }

    @Test("skipped item inspect command falls back to item list when item ID is missing")
    func skippedItemInspectCommandFallsBackToItemListWhenItemIDIsMissing() {
        let skipped = SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "share-7",
            itemIndex: 7,
            itemId: nil,
            codingPath: "items.Index 7.content",
            reason: "expected String"
        )

        let command = skipped.inspectCommand(cliSelection: .system(path: "/opt/homebrew/bin/pass-cli"))

        #expect(command.contains("# Item ID was not available. Inspect zero-based index 7 in the returned items array."))
        #expect(command.contains("/opt/homebrew/bin/pass-cli item list --share-id=share-7 --output json"))
    }

    @Test("sync coordinator helper can build generic presentation from an error")
    func genericPresentationFromError() {
        let presentation = SyncCoordinator.syncErrorPresentation(
            for: CLIError.parseError("expected String at items.Index 289.content"),
            cliSelection: .bundled(path: "/app/pass-cli", architecture: .arm64)
        )

        #expect(presentation.visibleMessage == "Sorry, there was a sync error.")
        #expect(presentation.action == .copyAndReport)
        #expect(presentation.diagnosticReport?.contains("CLIError.parseError") == true)
        #expect(presentation.diagnosticReport?.contains("expected String at items.Index 289.content") == true)
    }

    @Test("sync coordinator helper includes skipped diagnostics after partial fetch")
    func genericPresentationIncludesSkippedDiagnostics() {
        let skipped = SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            shareId: "share-7",
            itemIndex: 7,
            itemId: "item-7",
            codingPath: "items.Index 7.content",
            reason: "failed for user@example.com at /Users/alice/item"
        )
        let presentation = SyncCoordinator.syncErrorPresentation(
            for: CLIError.commandFailed("database write failed"),
            cliSelection: .system(path: "/opt/homebrew/bin/pass-cli"),
            skippedItems: [skipped],
            diagnosticFileURL: URL(fileURLWithPath: "/Users/alice/Library/Caches/SyncDiagnostics/report.txt")
        )

        #expect(presentation.diagnosticReport?.contains("Skipped items (showing first 1 of 1):") == true)
        #expect(presentation.diagnosticReport?.contains("share_id=share-7") == true)
        #expect(presentation.diagnosticReport?.contains("item_id=item-7") == true)
        #expect(presentation.diagnosticReport?.contains("Full skipped-item diagnostics file: ~/Library/Caches/SyncDiagnostics/report.txt") == true)
        #expect(presentation.diagnosticReport?.contains("user@example.com") == false)
        #expect(presentation.diagnosticReport?.contains("/Users/alice") == false)
    }

    @Test("sync coordinator helper builds login presentation for auth errors")
    func loginPresentationFromAuthError() {
        let presentation = SyncCoordinator.syncErrorPresentation(
            for: CLIError.notLoggedIn,
            cliSelection: .system(path: "/opt/homebrew/bin/pass-cli")
        )

        #expect(presentation.visibleMessage == "Please log in to Proton Pass CLI.")
        #expect(presentation.action == .login)
        #expect(presentation.diagnosticReport == nil)
    }

    @Test("mailto URL addresses support and keeps diagnostics out of the body")
    func mailtoURLUsesShortBody() throws {
        let url = try #require(SyncErrorDiagnosticReport.mailtoURL())
        let absolute = url.absoluteString
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        let subject = queryItems.first { $0.name == "subject" }?.value
        let body = queryItems.first { $0.name == "body" }?.value

        #expect(absolute.hasPrefix("mailto:yes@petr.codes"))
        #expect(subject == "Quick Access for Pass sync error")
        #expect(body?.contains("Diagnostic details were copied") == true)
        #expect(body?.contains("Quick Access for Pass Sync Diagnostic Report") == false)
    }
}
