import Foundation

extension RunAuthWindowController {
    func anyCachedMatch(
        appIdentifier: String,
        profileSlug: String,
        scopeOptions: [String]
    ) -> String? {
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
    ) -> String? {
        for scope in scopeOptions {
            let decision = try? databaseManager.findValidRunDecision(
                appIdentifier: appIdentifier,
                subcommand: scope,
                profileSlug: profileSlug
            )
            if decision != nil {
                return scope
            }
        }
        return nil
    }

    private func sessionCachedScope(
        appIdentifier: String,
        profileSlug: String,
        scopeOptions: [String]
    ) -> String? {
        let now = Date()
        for scope in scopeOptions {
            let key = Self.sessionKey(
                appIdentifier: appIdentifier,
                profileSlug: profileSlug,
                scope: scope
            )
            if let expiry = sessionCache[key], expiry > now {
                return scope
            }
        }
        return nil
    }

    func storeSessionCache(appIdentifier: String, profileSlug: String, scope: String) {
        let key = Self.sessionKey(
            appIdentifier: appIdentifier,
            profileSlug: profileSlug,
            scope: scope
        )
        sessionCache[key] = Date().addingTimeInterval(sessionCacheDuration)
    }

    func pruneSessionCache() {
        let now = Date()
        sessionCache = sessionCache.filter { $0.value > now }
    }

    private static func sessionKey(
        appIdentifier: String,
        profileSlug: String,
        scope: String
    ) -> String {
        "\(appIdentifier)|\(profileSlug)|\(scope)"
    }
}
