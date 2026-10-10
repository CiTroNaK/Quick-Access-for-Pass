import Darwin
import Foundation
import Synchronization
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill broker partial delivery ownership")
struct AutoFillBrokerPartialDeliveryTests {
    @Test
    @MainActor
    func processorKeepsAcceptedDescriptorOwnedThroughTerminalCleanup() async throws {
        var first = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        let acceptedFD = first[0]
        var peerIsOpen = true
        defer {
            if peerIsOpen { close(first[1]) }
        }
        var sendBuffer: Int32 = 1024
        guard setsockopt(acceptedFD, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(acceptedFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        let registry = AutoFillRequestRegistry()
        let launchGate = AutoFillLaunchGate()
        let guardState = SecretReleaseGuard()
        let trace = BrokerTestTrace()
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "user@example.test", serviceIdentifier: "example.test", hasTOTP: false
        )
        let request = AutoFillBrokerRequest(
            requestID: UUID(), descriptorID: descriptor.id, valueKind: .password,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        )
        let registeredRequest = AutoFillRegisteredRequest(
            requestID: request.requestID, descriptorID: request.descriptorID,
            kind: request.valueKind, deadline: request.deadlineUptimeNanoseconds
        )
        let diagnostics = PartialDeliveryDiagnostics()
        diagnostics.record(.requestPrepared)
        var observedByteCount: Int?
        var observedTerminalState = "notQueried"
        defer {
            diagnostics.report(
                deadline: request.deadlineUptimeNanoseconds,
                byteCount: observedByteCount,
                terminalState: observedTerminalState,
                trace: trace.snapshot()
            )
        }
        // Constructing this MainActor-only final-release object is not part of
        // the terminal wire condition under test. Build the exact request-bound
        // instance before the detached owner begins, while deliver() itself
        // remains the real MainActor final descriptor/guard/write boundary.
        let release = AutoFillCredentialRelease(
            request: registeredRequest, descriptor: descriptor, releaseToken: guardState.capture(),
            descriptorStore: PartialDeliveryDescriptorStore(descriptor: descriptor, diagnostics: diagnostics),
            secretReleaseGuard: guardState, isAppLocked: { false },
            now: { DispatchTime.now().uptimeNanoseconds }
        )
        trace.record(.releaseConstructed)
        let dependencies = AutoFillBrokerConnectionProcessor.Dependencies(
            registry: registry, launchGate: launchGate,
            verifier: { fd in
                diagnostics.record(.verifierEntered)
                return VerifiedAutoFillPeer(
                    fileDescriptor: fd, identifier: AutoFillConstants.extensionBundleIdentifier,
                    teamID: "H23TXL6LPT"
                )
            },
            requestHandler: { admittedRequest, _, _ in
                diagnostics.record(.handlerEntered)
                trace.record(.handler)
                trace.record(admittedRequest.deadline > DispatchTime.now().uptimeNanoseconds ? .handlerDeadlineFuture : .handlerDeadlineExpired)
                guard admittedRequest == registeredRequest else {
                    throw AutoFillProtocolError.malformedMessage
                }
                trace.record(.handlerReturned)
                diagnostics.record(.handlerReturned)
                return AutoFillCredentialDelivery(value: ResolvedSecret(value: String(repeating: "x", count: 60_000), offlineCapability: nil), release: release)
            },
            candidateHandler: { _ in [] },
            completionGate: diagnostics.observer(for: .registryCompleted),
            partialDeliveryGate: diagnostics.observer(for: .partialCleanupReached)
        )
        let processorExecutor = BrokerProcessorTaskExecutor()
        let owner = BrokerProcessorTaskFactory.start(
            fd: acceptedFD,
            dependencies: dependencies,
            executor: processorExecutor,
            diagnostics: diagnostics
        )
        do {
            try AutoFillWire.writeMessage(request, toFileDescriptor: first[1])
            diagnostics.record(.requestWritten)
            await owner.value
            diagnostics.record(.ownerJoined)
            let bytes = try await BrokerTestSocketIO.readUntilEOF(from: first[1])
            observedByteCount = bytes.count
            diagnostics.record(.peerEOFRead)
            let terminal = await registry.terminalResult(for: request.requestID)
            let terminalState = terminal?.state.rawValue ?? "none"
            observedTerminalState = terminalState
            diagnostics.record(.terminalStateRead)
            guard bytes.count > MemoryLayout<UInt32>.size else {
                Issue.record("Partial credential stream had no payload bytes; byteCount=\(bytes.count), terminal=\(terminalState), trace=\(trace.snapshot().map(\.rawValue).joined(separator: ","))")
                return
            }
            let frameLength = bytes.prefix(MemoryLayout<UInt32>.size).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let body = bytes.dropFirst(MemoryLayout<UInt32>.size)
            #expect(terminal?.state == .completed)
            #expect(trace.snapshot().contains(.releaseConstructed))
            #expect(trace.snapshot().contains(.handler))
            #expect(trace.snapshot().contains(.handlerReturned))
            if UInt32(body.count) == frameLength {
                let response = try AutoFillWire.decodeResponse(
                    AutoFillBrokerResponse.self, from: Data(body), matching: request.requestID
                )
                switch response {
                case .credential:
                    trace.record(.credentialResponse)
                    Issue.record("unexpected complete credential stream; terminal=\(terminalState), trace=\(trace.snapshot().map(\.rawValue).joined(separator: ","))")
                case .failure(_, let failure):
                    trace.record(failure == .expired ? .expiredResponse : .failureResponse)
                    #expect(failure == .expired)
                    #expect(DispatchTime.now().uptimeNanoseconds >= request.deadlineUptimeNanoseconds)
                case .candidates:
                    trace.record(.failureResponse)
                    Issue.record("unexpected candidate response; terminal=\(terminalState), trace=\(trace.snapshot().map(\.rawValue).joined(separator: ","))")
                }
            } else {
                #expect(UInt32(body.count) < frameLength)
                #expect(body.contains(0) == false)
            }
        } catch {
            if peerIsOpen {
                close(first[1])
                peerIsOpen = false
            }
            await owner.value
            throw error
        }
        if peerIsOpen {
            close(first[1])
            peerIsOpen = false
        }
    }
}

/// Starts the direct processor from a nonisolated context so its initial
/// blocking wire read cannot inherit this test's MainActor isolation.
private enum BrokerProcessorTaskFactory {
    nonisolated static func start(
        fd: Int32,
        dependencies: AutoFillBrokerConnectionProcessor.Dependencies,
        executor: BrokerProcessorTaskExecutor,
        diagnostics: PartialDeliveryDiagnostics? = nil
    ) -> Task<Void, Never> {
        Task(executorPreference: executor) {
            diagnostics?.record(.processorEntered)
            defer {
                close(fd)
                diagnostics?.record(.ownerClosed)
            }
            await AutoFillBrokerConnectionProcessor.processConnection(fd: fd, dependencies: dependencies)
            diagnostics?.record(.processorReturned)
        }
    }
}

/// Bounded test-only metadata: never response bytes, IDs, descriptors or errors.
private struct PartialDeliveryDiagnostics: Sendable {
    enum Phase: String, Sendable {
        case requestPrepared, requestWritten, processorEntered, verifierEntered
        case handlerEntered, handlerReturned, processorReturned, ownerClosed
        case ownerJoined, peerEOFRead, terminalStateRead
        case registryCompleted, descriptorLookupEntered, descriptorLookupReturned, partialCleanupReached
    }

    private let phases = OSAllocatedUnfairLock(initialState: [(Phase, UInt64)]())

    func record(_ phase: Phase) {
        phases.withLock { phases in
            guard phases.count < 32 else { return }
            phases.append((phase, DispatchTime.now().uptimeNanoseconds))
        }
    }

    /// Build existing-hook callbacks outside the MainActor fixture context.
    /// They record metadata and return immediately without a gate or wait.
    nonisolated func observer(for phase: Phase) -> @Sendable () async -> Void {
        { self.record(phase) }
    }

    func report(deadline: UInt64, byteCount: Int?, terminalState: String, trace: [BrokerTestTrace.Event]) {
        let snapshot = phases.withLock { phases in
            phases.map { "\($0.0.rawValue)@\($0.1)" }.joined(separator: ",")
        }
        let count = byteCount.map(String.init) ?? "unread"
        let events = trace.map(\.rawValue).joined(separator: ",")
        print("Broker partial delivery diagnostics: byteCount=\(count); terminal=\(terminalState); deadline=\(deadline); phases=\(snapshot); trace=\(events)")
    }
}

/// Keeps the direct processor's blocking read off cooperative executors.
private final class BrokerProcessorTaskExecutor: TaskExecutor, Sendable {
    private let queue = DispatchQueue(label: "AutoFillBrokerPartialDeliveryTests.processor")

    func enqueue(_ job: UnownedJob) {
        queue.async { [self, job] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

private actor PartialDeliveryDescriptorStore: AutoFillDescriptorStoring {
    let descriptorValue: AutoFillCredentialDescriptor
    private let diagnostics: PartialDeliveryDiagnostics?

    init(descriptor: AutoFillCredentialDescriptor, diagnostics: PartialDeliveryDiagnostics? = nil) {
        descriptorValue = descriptor
        self.diagnostics = diagnostics
    }

    func descriptor(id: UUID) async throws -> AutoFillCredentialDescriptor? {
        diagnostics?.record(.descriptorLookupEntered)
        defer { diagnostics?.record(.descriptorLookupReturned) }
        return id == descriptorValue.id ? descriptorValue : nil
    }
}
