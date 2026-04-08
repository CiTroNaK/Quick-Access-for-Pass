import Foundation
import Observation

/// Observable source of truth for Pass CLI info surfaced on the Pass CLI settings tab.
/// Owned by AppDelegate, injected via .environment(...). Sole writer is
/// `HealthCheckCoordinator.tickCLI()`, which runs on each CLI probe tick
/// (launch, wake, Settings becomes key, menu-bar "Refresh Now", and every 30 s).
@Observable
@MainActor
final class PassCLIStatusStore {
    var health: PassCLIHealth = .ok
    var identity: PassCLIIdentity?
    var version: String?

    init() {}
}
