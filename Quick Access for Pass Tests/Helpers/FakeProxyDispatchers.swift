import Foundation
@testable import Quick_Access_for_Pass

/// Test fake for `RunProxyDispatching`. Marked `@MainActor` explicitly
/// because the test target does NOT enable `SWIFT_DEFAULT_ACTOR_ISOLATION`
/// (only the main app target and qa-run helper do). The explicit annotation
/// makes the fake's mutable state Sendable-safe without `@unchecked Sendable`.
@MainActor
final class FakeRunProxyDispatcher: RunProxyDispatching {
    // Test-controlled inputs
    var lastEnabled: Bool = false
    var isProxyLive: Bool = false

    // Observable outputs for assertions
    var probeResults: [RunProbeResult] = []
    var cliTransitions: [PassCLIHealth] = []
    var wakeCallCount: Int = 0

    func handleRunProbeResult(_ result: RunProbeResult) async {
        probeResults.append(result)
    }

    func handleCLIHealthTransition(to health: PassCLIHealth) {
        cliTransitions.append(health)
    }

    func handleWake() async {
        wakeCallCount += 1
    }
}

/// Test fake for `SSHProxyDispatching`. Same shape as
/// `FakeRunProxyDispatcher` except `handleSSHProbeResult` takes
/// `SSHProbeResult` and `handleCLIHealthTransition(to:)` is `async`
/// to match the SSH protocol's isolation.
@MainActor
final class FakeSSHProxyDispatcher: SSHProxyDispatching {
    // Test-controlled inputs
    var lastEnabled: Bool = false
    var isProxyLive: Bool = false

    // Observable outputs for assertions
    var probeResults: [SSHProbeResult] = []
    var cliTransitions: [PassCLIHealth] = []
    var wakeCallCount: Int = 0

    func handleSSHProbeResult(_ result: SSHProbeResult) async {
        probeResults.append(result)
    }

    func handleCLIHealthTransition(to health: PassCLIHealth) async {
        cliTransitions.append(health)
    }

    func handleWake() async {
        wakeCallCount += 1
    }
}
