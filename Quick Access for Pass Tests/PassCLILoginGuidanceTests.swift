import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Pass CLI login guidance")
struct PassCLILoginGuidanceTests {
    @Test("bundled CLI guidance uses app login and omits terminal fallback")
    func bundledGuidanceOmitsTerminalFallback() {
        let selection = PassCLISelection.bundled(path: "/App/Contents/Helpers/pass-cli-arm64", version: "2.2.1", architecture: .arm64, requested: .latest, fallbackReason: nil)

        let message = selection.loginRequiredMessage

        #expect(message == String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in."))
        #expect(!message.contains("pass-cli login"))
        #expect(message.contains("Settings → Pass CLI"))
    }

    @Test("unresolved CLI guidance uses app login and omits terminal fallback")
    func unresolvedGuidanceOmitsTerminalFallback() {
        let selection = PassCLISelection.unresolved(command: "pass-cli")

        let message = selection.loginRequiredMessage

        #expect(message == String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in."))
        #expect(!message.contains("pass-cli login"))
        #expect(message.contains("Settings → Pass CLI"))
    }

    @Test("installed CLI guidance includes terminal fallback")
    func installedGuidanceIncludesTerminalFallback() {
        let selection = PassCLISelection.installed(path: "/opt/homebrew/bin/pass-cli", fallbackReason: nil)

        let message = selection.loginRequiredMessage

        #expect(message == String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in. You can also run `pass-cli login` in Terminal."))
        #expect(message.contains("pass-cli login"))
        #expect(message.contains("Terminal"))
    }

    @Test("custom CLI guidance includes terminal fallback")
    func customGuidanceIncludesTerminalFallback() {
        let selection = PassCLISelection.custom(path: "/custom/pass-cli")

        let message = selection.loginRequiredMessage

        #expect(message == String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in. You can also run `pass-cli login` in Terminal."))
        #expect(message.contains("pass-cli login"))
        #expect(message.contains("Terminal"))
    }

    @Test("SSH guidance preserves SSH context and follows fallback policy")
    func sshGuidancePreservesContext() {
        let bundled = PassCLISelection.bundled(path: "/App/Contents/Helpers/pass-cli-arm64", version: "2.2.1", architecture: .arm64, requested: .latest, fallbackReason: nil)
        let system = PassCLISelection.installed(path: "/opt/homebrew/bin/pass-cli", fallbackReason: nil)

        #expect(bundled.sshLoginRequiredMessage == String(localized: "SSH agent requires Pass CLI login. Open Settings → Pass CLI to log in."))
        #expect(!bundled.sshLoginRequiredMessage.contains("pass-cli login"))
        #expect(system.sshLoginRequiredMessage == String(localized: "SSH agent requires Pass CLI login. Open Settings → Pass CLI to log in. You can also run `pass-cli login` in Terminal."))
        #expect(system.sshLoginRequiredMessage.contains("pass-cli login"))
    }

    @Test("generic CLIError not logged in message is settings first without source-specific fallback")
    func genericCLIErrorMessageIsSettingsFirst() throws {
        let message = try #require(CLIError.notLoggedIn.errorDescription)

        #expect(message == String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in."))
        #expect(!message.contains("pass-cli login"))
        #expect(message.contains("Settings → Pass CLI"))
    }
}
