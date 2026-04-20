import AppKit
import Foundation

@MainActor
extension QuickAccessViewModel {
    func handleAction(_ action: ItemAction, for item: PassItem) {
        // May be called directly by the UI or re-entered from handleEnter/handleKeyDown;
        // onActivity must be idempotent because the compound path fires it twice.
        onActivity()
        switch action {
        case .copyUsername:
            handleCopyUsername(for: item)
            return
        case .openURL:
            handleOpenURL(for: item)
            return
        default:
            break
        }

        isActionLoading = true
        Task {
            defer { isActionLoading = false }
            do {
                try await handleSecretAction(action, for: item)
                try? searchService.recordUsage(itemId: item.id)
                onDismiss()
            } catch let error as CLIError where error.isAuthError {
                errorMessage = "Please log in: pass-cli login"
            } catch {
                errorMessage = "Failed: \(error.localizedDescription)"
            }
        }
    }

    func defaultAction(for type: ItemType) -> ItemAction {
        switch type {
        case .login: .copyPassword
        case .creditCard, .note, .identity, .alias, .sshKey, .wifi, .custom: .copyPrimary
        }
    }

    func actionsForItem(_ item: PassItem) -> [(action: ItemAction, label: String, shortcut: String)] {
        var actions: [(ItemAction, String, String)]
        switch item.itemType {
        case .login:
            actions = [
                (.copyUsername, String(localized: "Copy Username"),
                 shortcutLabel(codeKey: DefaultsKey.copyUsernameKeyCode, modsKey: DefaultsKey.copyUsernameModifiers)),
                (.copyPassword, String(localized: "Copy Password"),
                 shortcutLabel(codeKey: DefaultsKey.copyPasswordKeyCode, modsKey: DefaultsKey.copyPasswordModifiers)),
            ]
            if item.hasTOTP {
                actions.append((.copyTotp, String(localized: "Copy TOTP"),
                                shortcutLabel(codeKey: DefaultsKey.copyTotpKeyCode, modsKey: DefaultsKey.copyTotpModifiers)))
            }
            if item.url != nil {
                actions.append((.openURL, String(localized: "Open in Browser"), "⌘O"))
            }
        case .creditCard:
            actions = [(.copyPrimary, String(localized: "Copy Card Number"), "⌘C")]
        case .note:
            actions = [(.copyPrimary, String(localized: "Copy Note"), "⌘C")]
        case .identity:
            actions = [(.copyPrimary, String(localized: "Copy Email"), "⌘C")]
        case .alias:
            actions = [(.copyPrimary, String(localized: "Copy Alias"), "⌘C")]
        case .sshKey:
            actions = [(.copyPrimary, String(localized: "Copy Public Key"), "⌘C")]
        case .wifi:
            actions = [(.copyPrimary, String(localized: "Copy Password"), "⌘C")]
        case .custom:
            actions = [(.copyPrimary, String(localized: "Copy Content"), "⌘C")]
        }
        return actions
    }

    private func handleCopyUsername(for item: PassItem) {
        clipboardManager.copy(item.subtitle, label: String(localized: "Username copied"))
        try? searchService.recordUsage(itemId: item.id)
        onDismiss()
    }

    private func handleOpenURL(for item: PassItem) {
        guard let urlString = item.url, let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
        onDismiss()
    }

    private func handleSecretAction(_ action: ItemAction, for item: PassItem) async throws {
        switch action {
        case .copyPassword:
            lastCommand = "\(cliService.cliPath) item view --output json pass://\(item.vaultId)/\(item.id)"
            let detail = try await cliService.viewItem(itemId: item.id, shareId: item.vaultId)
            if case .login(let login) = detail.content.content {
                clipboardManager.copy(login.password, label: String(localized: "Password copied"))
            }
        case .copyTotp:
            lastCommand = "\(cliService.cliPath) item totp --output json pass://\(item.vaultId)/\(item.id)"
            let code = try await cliService.getTotp(itemId: item.id, shareId: item.vaultId)
            clipboardManager.copy(code, label: String(localized: "TOTP code copied"))
        case .copyPrimary:
            lastCommand = "\(cliService.cliPath) item view --output json pass://\(item.vaultId)/\(item.id)"
            try await copyPrimarySecret(for: item)
        case .copyUsername, .openURL:
            return
        }
    }

    private func shortcutLabel(codeKey: String, modsKey: String) -> String {
        let defaults = UserDefaults.standard
        let code = defaults.integer(forKey: codeKey)
        let mods = defaults.integer(forKey: modsKey)
        return ShortcutFormatting.label(keyCode: code, modifiers: mods)
    }

    private func copyPrimarySecret(for item: PassItem) async throws {
        let detail = try await cliService.viewItem(itemId: item.id, shareId: item.vaultId)
        let content = detail.content.content

        switch content {
        case .login(let login):
            clipboardManager.copy(login.password, label: String(localized: "Password copied"))
        case .creditCard(let card):
            clipboardManager.copy(card.number, label: String(localized: "Card number copied"))
        case .note:
            clipboardManager.copy(detail.content.note, label: String(localized: "Note copied"))
        case .identity(let identity):
            clipboardManager.copy(identity.email, label: String(localized: "Email copied"))
        case .alias:
            clipboardManager.copy(item.title, label: String(localized: "Alias copied"))
        case .sshKey(let key):
            clipboardManager.copy(key.publicKey, label: String(localized: "Public key copied"))
        case .wifi(let wifi):
            clipboardManager.copy(wifi.password, label: String(localized: "Password copied"))
        case .custom:
            clipboardManager.copy(detail.content.note, label: String(localized: "Content copied"))
        }
    }
}
