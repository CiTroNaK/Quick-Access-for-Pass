import Foundation

extension RunAuthWindowController {
    /// Matches ordered full scope keys (exact before prefixes), preferring session only within the same scope.
    func anyCachedMatch(
        appIdentifier: String,
        profileSlug: String,
        scopeOptions: [String]
    ) -> AuthorizationMatch? {
        let now = Date()
        for scope in scopeOptions {
            let key = SessionCacheKey(
                appIdentifier: appIdentifier,
                profileSlug: profileSlug,
                scope: scope
            )
            if let decision = sessionCache[key], decision.expiresAt > now {
                return AuthorizationMatch(scope: scope, allowed: decision.allowed)
            }
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

    func storeSessionCache(
        appIdentifier: String,
        profileSlug: String,
        scope: String,
        allowed: Bool
    ) {
        let key = SessionCacheKey(
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
}
