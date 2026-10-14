import AppKit

/// Presents explicit consent for CLI-owned local-session reset before browser login.
@MainActor
enum PassCLISessionRepairConfirmation {
    static func confirm() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Reset CLI Session and Log In?")
        alert.informativeText = String(localized: """
        This removes the local Pass CLI session and starts browser sign-in. \
        Other clients using the same session may be affected. \
        The old remote session may remain listed in Proton account settings. \
        Your saved token and Quick Access offline data will not be removed.
        """)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Reset Session and Log In"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}
