import Foundation

/// Invalidates in-flight secret deliveries when transient access is revoked.
///
/// The guard does not attempt to recall a value that was already released.
/// Callers capture a generation before asynchronous work and verify it at their
/// final release boundary.
@MainActor
final class SecretReleaseGuard {
    private var generation = UUID()
    private var terminallyBlocked = false

    func capture() -> UUID {
        generation
    }

    func isCurrent(_ token: UUID) -> Bool {
        !terminallyBlocked && generation == token
    }

    func revoke() {
        generation = UUID()
    }

    /// Irreversibly denies old and future capabilities during host termination.
    func blockReleasesForTermination() {
        terminallyBlocked = true
        generation = UUID()
    }
}
