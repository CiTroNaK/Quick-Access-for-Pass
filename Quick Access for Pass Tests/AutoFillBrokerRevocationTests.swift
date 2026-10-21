import Foundation
import Synchronization
import os
import Testing
@testable import Quick_Access_for_Pass

extension AutoFillBrokerTests {
    @Test("revocation after completion does not send a credential frame", .timeLimit(.minutes(1)))
    func revocationAfterRegistryCompletionDoesNotSendCredentialFrame() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let releaseGuard = SecretReleaseGuard()
        let didReachCompletion = OSAllocatedUnfairLock(initialState: false)
        let trace = BrokerTestTrace()
        let handoff = BrokerTestDeliveryHandoff()
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "test-vault", itemID: "test-item", shareID: "test-share",
            title: "Test", username: "test@example.test", serviceIdentifier: "example.test", hasTOTP: true
        )
        let broker = AutoFillBroker(
            listenPath: fixture.socketPath, registry: fixture.registry, launchGate: fixture.launchGate,
            verifier: { fd in
                VerifiedAutoFillPeer(
                    fileDescriptor: fd, identifier: AutoFillConstants.extensionBundleIdentifier, teamID: "H23TXL6LPT"
                )
            },
            requestHandler: { admittedRequest, _, _ in
                trace.record(.handler)
                trace.record(admittedRequest.deadline > DispatchTime.now().uptimeNanoseconds ? .handlerDeadlineFuture : .handlerDeadlineExpired)
                guard let delivery = handoff.delivery(matching: admittedRequest) else {
                    throw AutoFillProtocolError.malformedMessage
                }
                trace.record(.handlerReturned)
                return delivery
            },
            candidateHandler: { _ in [] },
            completionGate: {
                trace.record(.completionGate)
                await MainActor.run { releaseGuard.revoke() }
                didReachCompletion.withLock { $0 = true }
            }
        )
        try await broker.start()
        let socketPath = fixture.socketPath
        let clientTask = Task {
            try await BrokerTestSocketIO.requestWithPreparedDelivery(
                at: socketPath, handoff: handoff, trace: trace
            )
        }
        do {
            try await handoff.waitUntilWorkerReady()
            let prepared = await MainActor.run { () -> BrokerTestPreparedDelivery in
                let request = AutoFillBrokerRequest(
                    requestID: UUID(), descriptorID: descriptor.id, valueKind: .password,
                    deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000
                )
                let registeredRequest = AutoFillRegisteredRequest(
                    requestID: request.requestID, descriptorID: request.descriptorID,
                    kind: request.valueKind, deadline: request.deadlineUptimeNanoseconds
                )
                let release = AutoFillCredentialRelease(
                    request: registeredRequest, descriptor: descriptor, releaseToken: releaseGuard.capture(),
                    descriptorStore: makeAutoFillBrokerTestDescriptorStore(descriptor: descriptor),
                    secretReleaseGuard: releaseGuard, isAppLocked: { false },
                    now: { DispatchTime.now().uptimeNanoseconds }
                )
                return BrokerTestPreparedDelivery(
                    request: request, registeredRequest: registeredRequest,
                    delivery: AutoFillCredentialDelivery(value: ResolvedSecret(value: "must-not-be-delivered", offlineCapability: nil), release: release)
                )
            }
            trace.record(.releaseConstructed)
            try handoff.publish(prepared)
            let response = try await clientTask.value
            switch response {
            case .credential:
                Issue.record("A credential frame was delivered after revocation")
            case .failure:
                break
            case .candidates:
                Issue.record("Unexpected candidate response after revocation")
            }
        } catch {
            trace.record(.transportFailure)
            handoff.cancel()
            clientTask.cancel()
            _ = await clientTask.result
        }
        handoff.cancel()
        await broker.stop()
        if didReachCompletion.withLock({ $0 }) == false {
            Issue.record("revocation metadata trace: \(trace.snapshot().map(\.rawValue).joined(separator: ","))")
        }
        #expect(didReachCompletion.withLock { $0 })
    }
}
