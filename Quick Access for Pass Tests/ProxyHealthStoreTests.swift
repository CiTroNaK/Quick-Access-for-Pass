import Testing
import Foundation
@testable import Quick_Access_for_Pass

@MainActor
struct ProxyHealthStoreTests {

    @Test func sshAndRunHealthMutateIndependently() {
        let store = ProxyHealthStore()
        store.sshHealth = .ok(detail: "1 key")
        store.runHealth = .degraded(.probeFailed)
        #expect(store.sshHealth == .ok(detail: "1 key"))
        #expect(store.runHealth == .degraded(.probeFailed))
    }

    @Test func severityIncreasesOnWorseningTransition() {
        let store = ProxyHealthStore()
        store.sshHealth = .ok()
        #expect(store.sshHealth.severity == .nominal)
        store.sshHealth = .degraded(.probeFailed)
        #expect(store.sshHealth.severity == .degraded)
        store.sshHealth = .unreachable(.cooldown)
        #expect(store.sshHealth.severity == .unreachable)
    }
}
