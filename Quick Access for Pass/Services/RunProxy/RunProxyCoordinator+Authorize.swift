import AppKit
import Foundation

@MainActor
extension RunProxyCoordinator {
    func authorizeRunRequest(
        _ request: RunProxyRequest,
        connection: VerifiedConnection,
        authController: RunAuthWindowController
    ) async -> RunProxyResponse {
        var lockToken: UUID?
        defer {
            if let token = lockToken {
                clearPendingLockContext(token)
            }
        }

        guard let profile = try? databaseManager.findRunProfile(slug: request.profile) else {
            return RunProxyResponse(decision: .deny, env: nil)
        }

        if isAppLocked() {
            let appName = resolvedAppName(for: connection)
            let subcommand = RunAuthWindowController.extractSubcommand(from: request.command)
            let commandSummary = subcommand.isEmpty ? nil : subcommand
            let context = PendingLockContext.run(
                appName: appName,
                profileName: profile.name,
                commandSummary: commandSummary
            )
            lockToken = setPendingLockContext(context)
            guard let showPanel = showLockedPanel else {
                return RunProxyResponse(decision: .deny, env: nil)
            }
            let unlocked = await showPanel()
            guard unlocked else {
                return RunProxyResponse(decision: .deny, env: nil)
            }
        }

        guard let mappings = try? databaseManager.envMappings(forProfileId: profile.id!) else {
            return RunProxyResponse(decision: .deny, env: nil)
        }
        guard !mappings.isEmpty else {
            return RunProxyResponse(decision: .deny, env: nil)
        }

        guard let resolved = await resolveOrReuseSecrets(
            forProfileSlug: request.profile,
            profile: profile,
            mappings: mappings
        ) else {
            return RunProxyResponse(decision: .deny, env: nil)
        }

        return await authController.authorize(
            request: request,
            profileName: profile.name,
            env: resolved,
            connection: connection
        )
    }

    private func resolveOrReuseSecrets(
        forProfileSlug profileSlug: String,
        profile: RunProfile,
        mappings: [RunProfileEnvMapping]
    ) async -> [String: String]? {
        if let cached = resolvedSecrets[profileSlug],
           cacheIsFresh(profile: profile, resolvedAt: cached.resolvedAt) {
            return cached.env
        }
        do {
            let resolved = try await resolveSecrets(forProfileSlug: profileSlug, mappings: mappings)
            setResolvedSecrets(resolved, for: profileSlug)
            return resolved
        } catch {
            return nil
        }
    }

    private func cacheIsFresh(profile: RunProfile, resolvedAt: Date) -> Bool {
        guard let ttl = RememberDuration(rawValue: profile.cacheDuration) else {
            return false
        }
        switch ttl.resolved(from: resolvedAt) {
        case .doNotRemember: return false
        case .expires(let expiresAt): return Date() < expiresAt
        case .forever: return true
        }
    }

    private func resolvedAppName(for connection: VerifiedConnection) -> String {
        switch connection.identity {
        case .trustedHelper:
            return ProcessIdentifier.identifyParent(of: connection).name
        case .signedApp(let bundleID, _):
            let runningApp = NSRunningApplication(processIdentifier: connection.pid)
            return runningApp?.localizedName ?? bundleID
        case .unverified:
            return connection.identity.appIdentifier ?? "Unknown App"
        }
    }
}
