import AppKit
import Foundation

private enum SecretCopyError: LocalizedError {
    case aliasEmailUnavailable

    var errorDescription: String? {
        switch self {
        case .aliasEmailUnavailable:
            String(localized: "Alias email is unavailable because this pass-cli version does not expose it.")
        }
    }
}

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

        inFlightLargeType?.cancel()
        inFlightLargeType = nil
        largeTypeGeneration += 1
        inFlightCopy?.cancel()
        copyGeneration += 1
        let generation = copyGeneration
        let releaseToken = secretReleaseGuard.capture()
        inFlightCopy = Task { [weak self] in
            guard let self else { return }
            defer { self.finishCopyTaskIfCurrent(generation) }
            await self.runSecretActionTask(action, for: item, generation: generation, releaseToken: releaseToken)
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

    private func runSecretActionTask(
        _ action: ItemAction,
        for item: PassItem,
        generation: Int,
        releaseToken: UUID
    ) async {
        do {
            try await handleSecretAction(action, for: item, generation: generation, releaseToken: releaseToken)
            guard canReleaseCopy(generation, token: releaseToken) else { return }
            try? searchService.recordUsage(itemId: item.id)
            guard canReleaseCopy(generation, token: releaseToken) else { return }
            onDismiss()
        } catch is CancellationError {
            return
        } catch let error as OfflineSecretResolver.Error {
            publishCopyError(error.localizedDescription, generation: generation)
        } catch let error as CLIError where error.isAuthError {
            publishCopyError(cliService.cliSelection.loginRequiredMessage, generation: generation)
        } catch let error as SecretCopyError {
            publishCopyError(String(localized: "Failed: \(error.localizedDescription)"), generation: generation)
        } catch {
            publishCopyError(String(localized: "Failed to copy secret"), generation: generation)
        }
    }

    private func handleSecretAction(
        _ action: ItemAction,
        for item: PassItem,
        generation: Int,
        releaseToken: UUID
    ) async throws {
        let currentShareId = shareId(for: item)
        switch action {
        case .copyPassword:
            lastCommand = "\(cliService.cliPath) item view --output json pass://\(currentShareId)/\(item.id)"
            let detail = try await secretResolver.resolveItem(itemId: item.id, vaultId: item.vaultId, shareId: currentShareId)
            try Task.checkCancellation()
            guard canReleaseCopy(generation, token: releaseToken) else { return }
            let password = try detail.map { item in
                guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
                return login.password
            }
            try releaseCopy(password, label: String(localized: "Password copied"), generation: generation, token: releaseToken)
        case .copyTotp:
            lastCommand = "\(cliService.cliPath) item totp --output json pass://\(currentShareId)/\(item.id)"
            let code = try await secretResolver.resolveTOTP(itemId: item.id, vaultId: item.vaultId, shareId: currentShareId)
            try Task.checkCancellation()
            guard canReleaseCopy(generation, token: releaseToken) else { return }
            try releaseCopy(code, label: String(localized: "TOTP code copied"), generation: generation, token: releaseToken)
        case .copyPrimary:
            lastCommand = "\(cliService.cliPath) item view --output json pass://\(currentShareId)/\(item.id)"
            try await copyPrimarySecret(for: item, generation: generation, releaseToken: releaseToken)
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

    private func copyPrimarySecret(for item: PassItem, generation: Int, releaseToken: UUID) async throws {
        let detail = try await secretResolver.resolveItem(itemId: item.id, vaultId: item.vaultId, shareId: shareId(for: item))
        try Task.checkCancellation()
        guard canReleaseCopy(generation, token: releaseToken) else { return }
        let extracted = try detail.map { detail -> (String, String) in
            switch detail.content.content {
            case .login(let login): return (login.password, String(localized: "Password copied"))
            case .creditCard(let card): return (card.number, String(localized: "Card number copied"))
            case .note: return (detail.content.note, String(localized: "Note copied"))
            case .identity(let identity): return (identity.email, String(localized: "Email copied"))
            case .alias(let alias):
                let email = alias.email.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !email.isEmpty else { throw SecretCopyError.aliasEmailUnavailable }
                return (email, String(localized: "Alias copied"))
            case .sshKey(let key): return (key.publicKey, String(localized: "Public key copied"))
            case .wifi(let wifi): return (wifi.password, String(localized: "Password copied"))
            case .custom: return (detail.content.note, String(localized: "Content copied"))
            }
        }
        try releaseCopy(extracted.map { $0.0 }, label: extracted.value.1, generation: generation, token: releaseToken)
    }
}
