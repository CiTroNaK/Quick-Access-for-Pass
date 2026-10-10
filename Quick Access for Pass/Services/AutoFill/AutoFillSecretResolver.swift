import Foundation

nonisolated protocol AutoFillSecretResolving: Sendable {
    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind,
        context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String>
}

extension AutoFillSecretResolving {
    /// Focused resolver tests that are not broker-driven use ordinary context.
    func resolve(descriptor: AutoFillCredentialDescriptor, kind: AutoFillValueKind) async throws -> ResolvedSecret<String> {
        try await resolve(descriptor: descriptor, kind: kind, context: .ordinary)
    }
}

nonisolated enum AutoFillSecretResolverError: Error, Equatable, Sendable {
    case descriptorDoesNotSupportValue
    case itemIsNotLogin
    case usernameMismatch
    case unsupportedResolver
}

nonisolated func validateAutoFillUsername(
    _ login: CLILoginContent,
    expectedUsername: String?
) throws {
    guard let expectedUsername else { return }
    guard !expectedUsername.isEmpty else { throw AutoFillSecretResolverError.usernameMismatch }
    let identity = login.username.isEmpty ? login.email : login.username
    guard identity == expectedUsername else { throw AutoFillSecretResolverError.usernameMismatch }
}

/// The sole AutoFill adapter allowed to fetch credential values from Pass CLI.
/// Values are returned directly to the broker and are never logged or stored.
nonisolated struct PassCLIAutoFillSecretResolver: AutoFillSecretResolving {
    private let cliService: PassCLIService
    private let now: @Sendable () -> UInt64

    init(
        cliService: PassCLIService,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.cliService = cliService
        self.now = now
    }

    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind,
        context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String> {
        try Task.checkCancellation()
        if kind == .oneTimeCode, !descriptor.hasTOTP {
            throw AutoFillSecretResolverError.descriptorDoesNotSupportValue
        }
        return try await resolveLiveValue(
            itemId: descriptor.itemID,
            shareId: descriptor.shareID,
            kind: kind,
            context: context
        )
    }

    func resolveLiveValue(
        itemId: String,
        shareId: String,
        kind: AutoFillValueKind,
        context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String> {
        try Task.checkCancellation()
        try checkDeadline(context)
        let deadline = context.deadlineUptimeNanoseconds.map(CLIExecutionDeadline.init(uptimeNanoseconds:))
        let item: CLIItem
        if let deadline { item = try await cliService.viewItem(itemId: itemId, shareId: shareId, deadline: deadline) }
        else { item = try await cliService.viewItem(itemId: itemId, shareId: shareId) }
        try Task.checkCancellation()
        try checkDeadline(context)
        guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
        try validateAutoFillUsername(login, expectedUsername: context.expectedUsername)
        switch kind {
        case .password:
            return ResolvedSecret(value: login.password, offlineCapability: nil)
        case .oneTimeCode:
            guard !login.totpUri.isEmpty else { throw AutoFillSecretResolverError.descriptorDoesNotSupportValue }
            try Task.checkCancellation()
            try checkDeadline(context)
            let code: String
            if let deadline { code = try await cliService.getTotp(itemId: itemId, shareId: shareId, deadline: deadline) }
            else { code = try await cliService.getTotp(itemId: itemId, shareId: shareId) }
            try Task.checkCancellation()
            try checkDeadline(context)
            return ResolvedSecret(value: code, offlineCapability: nil)
        }
    }

    private func checkDeadline(_ context: SecretResolutionContext) throws {
        guard let deadline = context.deadlineUptimeNanoseconds else { return }
        guard deadline > now() else { throw SecretResolutionError.deadlineExpired }
    }
}
