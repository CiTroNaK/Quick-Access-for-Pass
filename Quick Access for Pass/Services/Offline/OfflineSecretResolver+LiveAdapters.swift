import Foundation

/// Live-only resolver used when offline mode has not been composed at a call site.
nonisolated struct LiveSecretItemResolver: SecretItemResolving {
    let cliService: PassCLIService

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        if let deadline = try OfflineAutoFillLiveBudget.deadline(context: context, now: DispatchTime.now().uptimeNanoseconds) {
            return ResolvedSecret(value: try await cliService.viewItem(itemId: itemId, shareId: shareId, deadline: deadline), offlineCapability: nil)
        }
        return ResolvedSecret(value: try await cliService.viewItem(itemId: itemId, shareId: shareId), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        if let deadline = try OfflineAutoFillLiveBudget.deadline(context: context, now: DispatchTime.now().uptimeNanoseconds) {
            return ResolvedSecret(value: try await cliService.getTotp(itemId: itemId, shareId: shareId, deadline: deadline), offlineCapability: nil)
        }
        return ResolvedSecret(value: try await cliService.getTotp(itemId: itemId, shareId: shareId), offlineCapability: nil)
    }

    func resolveAutoFillValue(
        itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String> {
        try await PassCLIAutoFillSecretResolver(cliService: cliService).resolveLiveValue(
            itemId: itemId, shareId: shareId, kind: kind, context: context
        )
    }
}

/// Compatibility adapter for existing focused ordinary-action tests. It cannot
/// serve a broker deadline because a closure cannot enforce native cancellation.
nonisolated struct LegacySecretItemResolver: SecretItemResolving {
    let fetchItem: CLIItemFetcher
    let cliService: PassCLIService

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        guard context.deadlineUptimeNanoseconds == nil else { throw SecretResolutionError.deadlineExpired }
        return ResolvedSecret(value: try await fetchItem(itemId, shareId), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        guard context.deadlineUptimeNanoseconds == nil else { throw SecretResolutionError.deadlineExpired }
        return ResolvedSecret(value: try await cliService.getTotp(itemId: itemId, shareId: shareId), offlineCapability: nil)
    }

    func resolveAutoFillValue(
        itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String> {
        throw AutoFillSecretResolverError.unsupportedResolver
    }
}
