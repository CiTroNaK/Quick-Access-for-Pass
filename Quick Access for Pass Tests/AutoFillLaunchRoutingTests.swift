import AppKit
import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill launch routing")
@MainActor
struct AutoFillLaunchRoutingTests {
    @Test("accepts only the exact non-secret AutoFill wake URL")
    func exactURLValidation() throws {
        let nonce = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let accepted = try #require(
            AutoFillLaunchURL.parse(
                URL(string: "quickaccesspass://autofill?nonce=\(nonce.uuidString)")!
            )
        )
        #expect(accepted == nonce)

        let rejected = [
            "other://autofill?nonce=\(nonce.uuidString)",
            "QUICKACCESSPASS://autofill?nonce=\(nonce.uuidString)",
            "quickaccesspass://other?nonce=\(nonce.uuidString)",
            "quickaccesspass://AUTOFILL?nonce=\(nonce.uuidString)",
            "quickaccesspass://autofill",
            "quickaccesspass://autofill?nonce=",
            "quickaccesspass://autofill?nonce=not-a-uuid",
            "quickaccesspass://autofill?nonce=\(nonce.uuidString)&nonce=\(UUID().uuidString)",
            "quickaccesspass://autofill?nonce=\(nonce.uuidString)&descriptor=\(UUID().uuidString)",
            "quickaccesspass://autofill/path?nonce=\(nonce.uuidString)",
            "quickaccesspass://user@autofill?nonce=\(nonce.uuidString)",
            "quickaccesspass://autofill:443?nonce=\(nonce.uuidString)",
            "quickaccesspass://autofill?nonce=\(nonce.uuidString)#fragment",
        ]

        for string in rejected {
            #expect(AutoFillLaunchURL.parse(URL(string: string)!) == nil, "Accepted \(string)")
        }
    }

    @Test("a valid cold URL synchronously gates admission before startup registration")
    func coldURLGatesBeforeStartupRegistration() async throws {
        let now = OSAllocatedUnfairLock(initialState: UInt64(10_000))
        let registry = AutoFillRequestRegistry(now: { now.withLock { $0 } })
        let delegate = AppDelegate()
        delegate.autoFillRequestRegistry = registry
        delegate.autoFillLaunchNow = { now.withLock { $0 } }
        let nonce = UUID()

        #expect(delegate.handleAutoFillLaunchURL(makeURL(nonce: nonce)))
        #expect(delegate.autoFillLaunchGate.requiresInitialClaim(at: 10_000))
        #expect(await registry.counts().wakeHandles == 0)

        #expect(delegate.autoFillLaunchGate.beginBrokerStart() == false)
        let registrations = delegate.autoFillLaunchGate.drainStartupRegistrations()
        #expect(registrations.count == 1)
        let registration = try #require(registrations.first)
        try await registry.registerWake(handle: registration.handle, deadline: registration.deadline)
        #expect(delegate.autoFillLaunchGate.beginBrokerStart())
        #expect(await registry.counts().wakeHandles == 1)
    }

    @Test("a warm URL registers asynchronously without re-gating admission")
    func warmURLRegistersWithoutRegating() async {
        let clock = ManualDeadlineClock()
        let registry = AutoFillRequestRegistry(now: { clock.now })
        let delegate = AppDelegate()
        delegate.autoFillRequestRegistry = registry
        delegate.autoFillLaunchNow = { clock.now }
        delegate.autoFillLaunchGate.markListenerReady()

        #expect(delegate.handleAutoFillLaunchURL(makeURL(nonce: UUID())))
        #expect(delegate.autoFillLaunchGate.requiresInitialClaim(at: 0) == false)
        #expect(await registrationIsObservable(in: registry))
    }

    private func registrationIsObservable(in registry: AutoFillRequestRegistry) async -> Bool {
        for _ in 0..<100 {
            if await registry.counts().wakeHandles == 1 { return true }
            // Drain the URL route's explicitly launched registration task and
            // its awaited registry actor turn without wall-clock waiting.
            await Task.yield()
        }
        return await registry.counts().wakeHandles == 1
    }

    private func makeURL(nonce: UUID) -> URL {
        URL(string: "quickaccesspass://autofill?nonce=\(nonce.uuidString)")!
    }
}
