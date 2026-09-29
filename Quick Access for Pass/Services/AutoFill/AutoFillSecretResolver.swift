import Foundation

nonisolated protocol AutoFillSecretResolving: Sendable {
    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind
    ) async throws -> String
}

nonisolated enum AutoFillSecretResolverError: Error, Equatable, Sendable {
    case descriptorDoesNotSupportValue
    case itemIsNotLogin
}

/// The sole AutoFill adapter allowed to fetch credential values from Pass CLI.
/// Values are returned directly to the broker and are never logged or stored.
nonisolated struct PassCLIAutoFillSecretResolver: AutoFillSecretResolving {
    private let cliService: PassCLIService

    init(cliService: PassCLIService) {
        self.cliService = cliService
    }

    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind
    ) async throws -> String {
        try Task.checkCancellation()
        switch kind {
        case .password:
            let item = try await cliService.viewItem(
                itemId: descriptor.itemID,
                shareId: descriptor.shareID
            )
            try Task.checkCancellation()
            guard case .login(let login) = item.content.content else {
                throw AutoFillSecretResolverError.itemIsNotLogin
            }
            return login.password
        case .oneTimeCode:
            guard descriptor.hasTOTP else {
                throw AutoFillSecretResolverError.descriptorDoesNotSupportValue
            }
            let code = try await cliService.getTotp(
                itemId: descriptor.itemID,
                shareId: descriptor.shareID
            )
            try Task.checkCancellation()
            return code
        }
    }
}
