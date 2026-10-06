import Foundation

nonisolated protocol AutoFillSecretResolving: Sendable {
    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind,
        context: SecretResolutionContext
    ) async throws -> String
}

extension AutoFillSecretResolving {
    /// Focused resolver tests that are not broker-driven use ordinary context.
    func resolve(descriptor: AutoFillCredentialDescriptor, kind: AutoFillValueKind) async throws -> String {
        try await resolve(descriptor: descriptor, kind: kind, context: .ordinary)
    }
}

nonisolated enum AutoFillSecretResolverError: Error, Equatable, Sendable {
    case descriptorDoesNotSupportValue
    case itemIsNotLogin
    case usernameMismatch
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
    ) async throws -> String {
        try Task.checkCancellation()
        switch kind {
        case .password:
            let item = try await viewItem(descriptor: descriptor, context: context)
            try Task.checkCancellation()
            guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
            try validateAutoFillUsername(login, expectedUsername: context.expectedUsername)
            try checkDeadline(context)
            return login.password
        case .oneTimeCode:
            guard descriptor.hasTOTP else { throw AutoFillSecretResolverError.descriptorDoesNotSupportValue }
            let item = try await viewItem(descriptor: descriptor, context: context)
            try Task.checkCancellation()
            try checkDeadline(context)
            guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
            try validateAutoFillUsername(login, expectedUsername: context.expectedUsername)
            // Recalculate immediately before this second native command: the
            // item lookup may have consumed most of the original broker budget.
            let timeout = try liveTimeout(context)
            let code: String
            if let timeout { code = try await cliService.getTotp(itemId: descriptor.itemID, shareId: descriptor.shareID, timeout: timeout) }
            else { code = try await cliService.getTotp(itemId: descriptor.itemID, shareId: descriptor.shareID) }
            try Task.checkCancellation()
            try checkDeadline(context)
            return code
        }
    }

    private func viewItem(descriptor: AutoFillCredentialDescriptor, context: SecretResolutionContext) async throws -> CLIItem {
        let timeout = try liveTimeout(context)
        if let timeout { return try await cliService.viewItem(itemId: descriptor.itemID, shareId: descriptor.shareID, timeout: timeout) }
        return try await cliService.viewItem(itemId: descriptor.itemID, shareId: descriptor.shareID)
    }

    private func liveTimeout(_ context: SecretResolutionContext) throws -> TimeInterval? {
        try OfflineAutoFillLiveBudget.timeout(context: context, hasSnapshot: false, now: now())
    }

    private func checkDeadline(_ context: SecretResolutionContext) throws {
        guard let deadline = context.deadlineUptimeNanoseconds else { return }
        guard deadline > now() else { throw SecretResolutionError.deadlineExpired }
    }
}
