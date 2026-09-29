import Foundation

extension RunAuthWindowController {
    func anyCachedMatch(
        appIdentifier: String,
        profileSlug: String,
        scopeOptions: [String]
    ) -> AuthorizationMatch? {
        sessionCachedScope(
            appIdentifier: appIdentifier,
            profileSlug: profileSlug,
            scopeOptions: scopeOptions
        ) ?? persistedScopeMatch(
            appIdentifier: appIdentifier,
            profileSlug: profileSlug,
            scopeOptions: scopeOptions
        )
    }

    private func persistedScopeMatch(
        appIdentifier: String,
        profileSlug: String,
        scopeOptions: [String]
    ) -> AuthorizationMatch? {
        for scope in scopeOptions {
            if let decision = try? databaseManager.findValidRunDecision(
                appIdentifier: appIdentifier,
                subcommand: scope,
                profileSlug: profileSlug
            ) {
                return AuthorizationMatch(scope: scope, allowed: decision.allowed)
            }
        }
        return nil
    }

    private func sessionCachedScope(
        appIdentifier: String,
        profileSlug: String,
        scopeOptions: [String]
    ) -> AuthorizationMatch? {
        let now = Date()
        for scope in scopeOptions {
            let key = Self.sessionKey(
                appIdentifier: appIdentifier,
                profileSlug: profileSlug,
                scope: scope
            )
            if let decision = sessionCache[key], decision.expiresAt > now {
                return AuthorizationMatch(scope: scope, allowed: decision.allowed)
            }
        }
        return nil
    }

    func storeSessionCache(
        appIdentifier: String,
        profileSlug: String,
        scope: String,
        allowed: Bool
    ) {
        let key = Self.sessionKey(
            appIdentifier: appIdentifier,
            profileSlug: profileSlug,
            scope: scope
        )
        sessionCache[key] = (
            allowed: allowed,
            expiresAt: Date().addingTimeInterval(sessionCacheDuration)
        )
    }

    func pruneSessionCache() {
        let now = Date()
        sessionCache = sessionCache.filter { $0.value.expiresAt > now }
    }

    private static func sessionKey(
        appIdentifier: String,
        profileSlug: String,
        scope: String
    ) -> String {
        "\(appIdentifier)|\(profileSlug)|\(scope)"
    }
}
