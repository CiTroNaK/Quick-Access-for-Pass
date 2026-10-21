import Foundation

extension RunAuthWindowController {
    /// Matches typed identities in exact-first order, preferring session only within the same identity.
    func anyCachedMatch(
        appIdentifier: String,
        profileSlug: String,
        scopeOptions: [RunAuthorizationIdentity]
    ) -> AuthorizationMatch? {
        let now = Date()
        for identity in scopeOptions {
            let key = SessionCacheKey(
                appIdentifier: appIdentifier,
                profileSlug: profileSlug,
                scope: identity
            )
            if let decision = sessionCache[key], decision.expiresAt > now {
                return AuthorizationMatch(identity: identity, allowed: decision.allowed)
            }
            if let decision = try? databaseManager.findValidRunDecision(
                appIdentifier: appIdentifier,
                identity: identity,
                profileSlug: profileSlug
            ) {
                return AuthorizationMatch(identity: identity, allowed: decision.allowed)
            }
        }
        return nil
    }

    func storeSessionCache(
        appIdentifier: String,
        profileSlug: String,
        scope: RunAuthorizationIdentity,
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
