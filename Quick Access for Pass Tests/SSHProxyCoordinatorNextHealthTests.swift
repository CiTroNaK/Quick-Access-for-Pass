import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("SSHProxyCoordinator.nextSSHHealth")
struct SSHProxyCoordinatorNextHealthTests {
    @Test(arguments: [
        (ProxyHealthState.unreachable(.passCLINotLoggedIn), 2,
         ProxyHealthState.unreachable(.passCLINotLoggedIn)),
        (ProxyHealthState.unreachable(.passCLIFailed("old")), 2,
         ProxyHealthState.unreachable(.passCLIFailed("old"))),
        (ProxyHealthState.ok(detail: "stale"), 1,
         ProxyHealthState.ok(detail: "1 key")),
        (ProxyHealthState.ok(detail: "stale"), 3,
         ProxyHealthState.ok(detail: "3 keys")),
        (ProxyHealthState.unreachable(.cooldown), 2,
         ProxyHealthState.ok(detail: "2 keys")),
        (ProxyHealthState.disabled, 2,
         ProxyHealthState.ok(detail: "2 keys")),
    ])
    func nextSSHHealthDecisionTable(
        current: ProxyHealthState,
        keyCount: Int,
        expected: ProxyHealthState
    ) {
        let actual = SSHProxyCoordinator.nextSSHHealth(
            onHealthyProbeGiven: current,
            withKeyCount: keyCount
        )
        #expect(actual == expected)
    }
}
