import Testing
import Foundation
@testable import Quick_Access_for_Pass

struct ProxyHealthStateTests {

    @Test(arguments: [
        (ProxyHealthState.ok(detail: nil), ProxyHealthState.Severity.nominal),
        (ProxyHealthState.ok(detail: "3 keys"), ProxyHealthState.Severity.nominal),
        (ProxyHealthState.disabled, ProxyHealthState.Severity.nominal),
        (ProxyHealthState.degraded(.emptyIdentities), ProxyHealthState.Severity.degraded),
        (ProxyHealthState.degraded(.probeFailed), ProxyHealthState.Severity.degraded),
        (ProxyHealthState.degraded(.clientLoopFailure), ProxyHealthState.Severity.degraded),
        (ProxyHealthState.unreachable(.probeFailed), ProxyHealthState.Severity.unreachable),
        (ProxyHealthState.unreachable(.cooldown), ProxyHealthState.Severity.unreachable),
        (ProxyHealthState.unreachable(.passCLINotLoggedIn), ProxyHealthState.Severity.unreachable),
    ])
    func severity(state: ProxyHealthState, expected: ProxyHealthState.Severity) {
        #expect(state.severity == expected,
                "expected severity \(expected) for \(state)")
    }

    @Test(arguments: ProxyHealthState.Reason.allKnown)
    func userFacingTextIsNonEmpty(reason: ProxyHealthState.Reason) {
        #expect(reason.userFacingText.isEmpty == false,
                "reason \(reason) has empty userFacingText")
    }
}
