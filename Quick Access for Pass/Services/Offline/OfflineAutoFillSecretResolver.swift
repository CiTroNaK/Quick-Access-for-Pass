import Foundation

/// Host-only AutoFill adapter. It receives a broker-verified descriptor and
/// returns only the requested value; snapshot/catalog access never reaches the extension.
nonisolated struct OfflineAutoFillSecretResolver: AutoFillSecretResolving {
    private let resolver: any SecretItemResolving

    init(resolver: any SecretItemResolving) { self.resolver = resolver }

    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind,
        context: SecretResolutionContext
    ) async throws -> String {
        try Task.checkCancellation()
        // The verified descriptor is the authorization context for every
        // cached decode, including direct adapter callers.
        let descriptorContext = SecretResolutionContext(
            deadlineUptimeNanoseconds: context.deadlineUptimeNanoseconds,
            expectedUsername: descriptor.username
        )
        switch kind {
        case .password:
            let item = try await resolver.resolveItem(
                itemId: descriptor.itemID, vaultId: descriptor.vaultID, shareId: descriptor.shareID, context: descriptorContext
            )
            try Task.checkCancellation()
            guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
            try validateAutoFillUsername(login, expectedUsername: descriptorContext.expectedUsername)
            return login.password
        case .oneTimeCode:
            guard descriptor.hasTOTP else { throw AutoFillSecretResolverError.descriptorDoesNotSupportValue }
            // Resolve the item first so both cached password and TOTP releases
            // verify the descriptor's current login identity.
            let item = try await resolver.resolveItem(
                itemId: descriptor.itemID, vaultId: descriptor.vaultID, shareId: descriptor.shareID, context: descriptorContext
            )
            guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
            try validateAutoFillUsername(login, expectedUsername: descriptorContext.expectedUsername)
            let code = try await resolver.resolveTOTP(
                itemId: descriptor.itemID, vaultId: descriptor.vaultID, shareId: descriptor.shareID, context: descriptorContext
            )
            try Task.checkCancellation()
            return code
        }
    }
}
