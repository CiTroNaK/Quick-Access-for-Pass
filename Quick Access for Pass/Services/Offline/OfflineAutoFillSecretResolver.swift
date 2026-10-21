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
    ) async throws -> ResolvedSecret<String> {
        try Task.checkCancellation()
        // The verified descriptor is the authorization context for every
        // cached decode, including direct adapter callers.
        let descriptorContext = SecretResolutionContext(
            deadlineUptimeNanoseconds: context.deadlineUptimeNanoseconds,
            expectedUsername: descriptor.username
        )
        if kind == .oneTimeCode, !descriptor.hasTOTP {
            throw AutoFillSecretResolverError.descriptorDoesNotSupportValue
        }
        let value = try await resolver.resolveAutoFillValue(
            itemId: descriptor.itemID,
            vaultId: descriptor.vaultID,
            shareId: descriptor.shareID,
            kind: kind,
            context: descriptorContext
        )
        try Task.checkCancellation()
        return value
    }
}
