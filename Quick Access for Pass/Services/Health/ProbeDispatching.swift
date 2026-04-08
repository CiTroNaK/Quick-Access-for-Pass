import Foundation

/// Protocol surface `HealthCheckCoordinator` needs from `RunProxyCoordinator`.
/// Exposes the two read properties the gate check consults (`lastEnabled`,
/// `isProxyLive`) and the three dispatch methods the tick bodies / wake
/// handler call.
///
/// Lets `HealthCheckCoordinator` hold an `any RunProxyDispatching` reference
/// so its tests can inject a fake dispatcher without constructing a real
/// `RunProxyCoordinator` (which requires `DatabaseManager`, `ProxyHealthStore`,
/// `FakeBiometricAuthorizer`, and a suite-scoped `UserDefaults`).
///
/// ## Invariant: one-directional dependency (unchanged from parent spec)
/// Conformers MUST NOT hold a reference back to `HealthCheckCoordinator`.
/// The dependency is one-directional: coordinator → dispatcher.
@MainActor
protocol RunProxyDispatching: AnyObject {
    var lastEnabled: Bool { get }
    var isProxyLive: Bool { get }
    func handleRunProbeResult(_ result: RunProbeResult) async
    func handleCLIHealthTransition(to health: PassCLIHealth)
    func handleWake() async
}

/// Protocol surface `HealthCheckCoordinator` needs from `SSHProxyCoordinator`.
/// Mirrors `RunProxyDispatching` with one asymmetry: `handleCLIHealthTransition`
/// is `async` on the SSH side because its `.ok` branch may await
/// `handleCLIHealthRecovered()` → `recoverProxyIfNeeded()` → `startProxy()`.
///
/// A unified parent protocol would have to widen Run's sync method to `async`,
/// forcing every call site to `await` an effectively-synchronous call. Two
/// separate protocols are cheaper than that widening.
@MainActor
protocol SSHProxyDispatching: AnyObject {
    var lastEnabled: Bool { get }
    var isProxyLive: Bool { get }
    func handleSSHProbeResult(_ result: SSHProbeResult) async
    func handleCLIHealthTransition(to health: PassCLIHealth) async
    func handleWake() async
}

// MARK: - Conformance

extension RunProxyCoordinator: RunProxyDispatching {
    /// Computed property exposing "is the underlying `proxy` instance
    /// non-nil?" without leaking the concrete `RunProxy?` type through
    /// the protocol. Returns `proxy != nil`.
    var isProxyLive: Bool { proxy != nil }
}

extension SSHProxyCoordinator: SSHProxyDispatching {
    /// Computed property exposing "is the underlying `proxy` instance
    /// non-nil?" without leaking the concrete `SSHAgentProxy?` type
    /// through the protocol. Returns `proxy != nil`.
    var isProxyLive: Bool { proxy != nil }
}
