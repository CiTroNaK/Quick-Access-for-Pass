import Foundation
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill launch gate")
struct AutoFillLaunchGateTests {
    @Test("a buffered launch wake blocks no-handle admission until its claim completes")
    func startupWakeRequiresClaim() {
        let gate = AutoFillLaunchGate()
        let handle = UUID()
        gate.recordWake(handle: handle, deadline: 200)

        #expect(gate.requiresInitialClaim(at: 100))
        gate.completeInitialClaim(handle: handle, deadline: 200)
        #expect(gate.requiresInitialClaim(at: 100) == false)
    }

    @Test("a URL recorded after the listener is ready does not re-gate warm requests")
    func warmWakeDoesNotRegate() {
        let gate = AutoFillLaunchGate()
        gate.markListenerReady()
        gate.recordWake(handle: UUID(), deadline: 200)
        #expect(gate.requiresInitialClaim(at: 100) == false)
    }

    @Test("expired startup wakes do not require a claim")
    func expiredStartupWakeDoesNotRequireClaim() {
        let gate = AutoFillLaunchGate()
        gate.recordWake(handle: UUID(), deadline: 100)

        #expect(gate.requiresInitialClaim(at: 100) == false)
    }
}
