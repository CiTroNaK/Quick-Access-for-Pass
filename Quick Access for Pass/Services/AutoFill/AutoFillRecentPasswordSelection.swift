import Foundation

/// Presentation-only memory of the last password delivered to the extension.
/// This is not evidence of website login success, a tab identity, or authorization.
@MainActor
final class AutoFillRecentPasswordSelection {
    private struct Selection {
        let descriptorID: UUID
        let serviceIdentifier: String
        let releaseToken: UUID
        let expiresAt: UInt64
    }

    private let now: @Sendable () -> UInt64
    private let secretReleaseGuard: SecretReleaseGuard
    private let isAppLocked: @MainActor @Sendable () -> Bool
    private var selection: Selection?

    init(
        now: @escaping @Sendable () -> UInt64,
        secretReleaseGuard: SecretReleaseGuard,
        isAppLocked: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.now = now
        self.secretReleaseGuard = secretReleaseGuard
        self.isAppLocked = isAppLocked
    }

    func recordDelivery(descriptorID: UUID, serviceIdentifier: String, releaseToken: UUID) {
        guard secretReleaseGuard.isCurrent(releaseToken), isAppLocked() == false else { return }
        let (expiry, overflow) = now().addingReportingOverflow(120_000_000_000)
        selection = Selection(
            descriptorID: descriptorID, serviceIdentifier: serviceIdentifier,
            releaseToken: releaseToken, expiresAt: overflow ? UInt64.max : expiry
        )
    }

    func clear() { selection = nil }

    func candidates(_ candidates: [AutoFillCandidate], for query: AutoFillCandidateQuery) -> [AutoFillCandidate] {
        guard let selection else { return candidates }
        guard selection.expiresAt > now(), secretReleaseGuard.isCurrent(selection.releaseToken), isAppLocked() == false else {
            clear()
            return candidates
        }
        guard case .site(_, let services, .oneTimeCode, _, _) = query,
              services.contains(where: { AutoFillServiceIdentifier.normalizedHost(for: $0) == selection.serviceIdentifier }),
              let index = candidates.firstIndex(where: { $0.descriptorID == selection.descriptorID && $0.kind == .oneTimeCode }) else {
            return candidates
        }
        var result = candidates
        let candidate = result.remove(at: index)
        let recent = AutoFillCandidate(
            descriptorID: candidate.descriptorID, title: candidate.title, username: candidate.username,
            kind: candidate.kind, matchTier: candidate.matchTier, isRecentlyUsed: true
        )
        // Preserve service specificity and the relative ordering of all other logins.
        let insertion = result.firstIndex(where: { $0.matchTier >= recent.matchTier }) ?? result.endIndex
        result.insert(recent, at: insertion)
        return result
    }
}
