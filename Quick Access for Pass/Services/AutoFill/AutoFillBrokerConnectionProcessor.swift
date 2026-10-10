import Darwin
import Foundation

nonisolated enum AutoFillBrokerConnectionProcessor {
    static let maximumRequestLifetimeNanoseconds: UInt64 = 30_000_000_000

    struct Dependencies: Sendable {
        let registry: AutoFillRequestRegistry
        let launchGate: AutoFillLaunchGate
        let verifier: @Sendable (Int32) throws -> VerifiedAutoFillPeer
        let requestHandler: AutoFillBrokerRequestHandler
        let candidateHandler: AutoFillBrokerCandidateHandler
        /// Test-only completion seam. Production leaves this nil; it cannot
        /// replace registry completion or bypass authenticated admission.
        let completionGate: (@Sendable () async -> Void)?
        /// Test-only observation point after typed partial-frame cleanup and
        /// before the accepted-connection owner closes its descriptor.
        let partialDeliveryGate: (@Sendable () async -> Void)?
    }

    struct Admission: Sendable {
        let connectionID: UUID
        let peer: VerifiedAutoFillPeer
        let wakeHandle: UUID?
        let deadline: UInt64
    }
}

private struct AutoFillCredentialResolution: Sendable {
    let requestID: UUID
    let descriptorID: UUID
    let kind: AutoFillValueKind
    let appAssociationIntent: AutoFillAppAssociationIntent?
}

nonisolated extension AutoFillBrokerConnectionProcessor {
    static func configureAcceptedSocket(_ fd: Int32, idleTimeout: TimeInterval) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }

        var noSIGPIPE: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))

        let wholeSeconds = floor(idleTimeout)
        var timeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((idleTimeout - wholeSeconds) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func processConnection(fd: Int32, dependencies: Dependencies) async {
        let connectionID = UUID()
        var admission: Admission?

        do {
            let peer = try dependencies.verifier(fd)
            let wireRequest = try AutoFillWire.readMessage(
                AutoFillBrokerRequest.self,
                fromFileDescriptor: fd
            )

            switch wireRequest {
            case .listCandidates(let query):
                admission = try await serveCandidates(
                    query,
                    connectionID: connectionID,
                    peer: peer,
                    fd: fd,
                    dependencies: dependencies
                )
            case .resolveCredential(
                let requestID,
                let descriptorID,
                let kind,
                let deadline,
                let wakeHandle,
                let appAssociationIntent
            ):
                // The authenticated request has been read in full. This owned
                // connection now enters its terminal response phase; no further
                // blocking reads are needed. Keep the one-way mode change until
                // the existing connection owner closes it. MSG_DONTWAIT alone
                // does not prevent a Darwin AF_UNIX send from blocking.
                let flags = fcntl(fd, F_GETFL, 0)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw AutoFillProtocolError.connectionClosed
                }
                let credentialAdmission = Admission(
                    connectionID: connectionID,
                    peer: peer,
                    wakeHandle: wakeHandle,
                    deadline: deadline
                )
                admission = try await serveCredential(
                    AutoFillCredentialResolution(
                        requestID: requestID,
                        descriptorID: descriptorID,
                        kind: kind,
                        appAssociationIntent: appAssociationIntent
                    ),
                    admission: credentialAdmission,
                    fd: fd,
                    dependencies: dependencies
                )
            }
        } catch {
            // Authentication, framing, replay, and capacity failures are fail-closed.
        }

        if let admission {
            await dependencies.registry.removeConnection(admission.connectionID)
        }
    }

    private static func serveCandidates(
        _ query: AutoFillCandidateQuery,
        connectionID: UUID,
        peer: VerifiedAutoFillPeer,
        fd: Int32,
        dependencies: Dependencies
    ) async throws -> Admission? {
        guard requestDeadlineIsValid(query.deadlineUptimeNanoseconds) else {
            try? writeFailure(.invalidRequest, requestID: query.requestID, to: fd)
            return nil
        }
        let admission = Admission(
            connectionID: connectionID,
            peer: peer,
            wakeHandle: query.wakeHandle,
            deadline: query.deadlineUptimeNanoseconds
        )
        guard try await bindAdmission(admission, dependencies: dependencies) else {
            try? writeFailure(.unauthorized, requestID: query.requestID, to: fd)
            return nil
        }
        do {
            let candidates = try await resolveWhileConnected(fd: fd, deadline: admission.deadline) {
                try await dependencies.candidateHandler(query)
            }
            guard candidates.count <= AutoFillCandidate.maximumCandidates else {
                throw AutoFillProtocolError.malformedMessage
            }
            try AutoFillWire.writeMessage(
                AutoFillBrokerResponse.candidates(requestID: query.requestID, candidates: candidates),
                toFileDescriptor: fd
            )
        } catch AutoFillBrokerError.disconnected {
            await dependencies.registry.removeConnection(connectionID)
            return nil
        } catch is CancellationError {
            try? writeFailure(.cancelled, requestID: query.requestID, to: fd)
        } catch AutoFillBrokerCoordinator.Error.deadlineExpired {
            try? writeFailure(.expired, requestID: query.requestID, to: fd)
        } catch {
            try? writeFailure(.resolutionFailed, requestID: query.requestID, to: fd)
        }
        return admission
    }

    private static func serveCredential(
        _ resolution: AutoFillCredentialResolution,
        admission: Admission,
        fd: Int32,
        dependencies: Dependencies
    ) async throws -> Admission? {
        guard requestDeadlineIsValid(admission.deadline) else {
            try? writeFailure(.invalidRequest, requestID: resolution.requestID, to: fd)
            return nil
        }
        guard try await bindAdmission(admission, dependencies: dependencies) else {
            try? writeFailure(.unauthorized, requestID: resolution.requestID, to: fd)
            return nil
        }

        let request: AutoFillRegisteredRequest
        do {
            request = try await beginCredentialRequest(
                resolution,
                admission: admission,
                registry: dependencies.registry
            )
        } catch {
            return admission
        }
        let connectionID = admission.connectionID

        await resolveCredential(
            request,
            connectionID: connectionID,
            appAssociationIntent: resolution.appAssociationIntent,
            fd: fd,
            dependencies: dependencies
        )
        return admission
    }

    private static func resolveCredential(
        _ request: AutoFillRegisteredRequest,
        connectionID: UUID,
        appAssociationIntent: AutoFillAppAssociationIntent?,
        fd: Int32,
        dependencies: Dependencies
    ) async {
        do {
            let delivery = try await resolveWhileConnected(fd: fd, deadline: request.deadline) {
                try await dependencies.requestHandler(request, { state in
                    try await dependencies.registry.transition(requestID: request.requestID, to: state)
                }, appAssociationIntent)
            }
            try await completeCredentialDelivery(
                delivery, request: request, connectionID: connectionID, fd: fd, dependencies: dependencies
            )
        } catch AutoFillWireDeliveryError.partialFrame {
            // Credential bytes are already on this stream. Do not append a
            // failure frame; the accepted-connection owner closes its fd after
            // this registry cleanup completes.
            _ = try? await dependencies.registry.fail(
                requestID: request.requestID,
                connectionID: connectionID,
                failure: .unavailable
            )
            if let partialDeliveryGate = dependencies.partialDeliveryGate {
                await partialDeliveryGate()
            }
        } catch AutoFillBrokerError.disconnected {
            _ = try? await dependencies.registry.fail(
                requestID: request.requestID,
                connectionID: connectionID,
                failure: .unavailable
            )
        } catch is CancellationError {
            if (try? await dependencies.registry.cancel(requestID: request.requestID, connectionID: connectionID)) == true {
                try? writeFailure(.cancelled, requestID: request.requestID, to: fd)
            }
        } catch AutoFillBrokerCoordinator.Error.deadlineExpired {
            _ = try? await dependencies.registry.fail(
                requestID: request.requestID,
                connectionID: connectionID,
                failure: .expired
            )
            try? writeFailure(.expired, requestID: request.requestID, to: fd)
        } catch {
            if (try? await dependencies.registry.fail(
                requestID: request.requestID,
                connectionID: connectionID,
                failure: .resolutionFailed
            )) == true {
                try? writeFailure(.resolutionFailed, requestID: request.requestID, to: fd)
            }
        }
    }

    private static func completeCredentialDelivery(
        _ delivery: AutoFillCredentialDelivery,
        request: AutoFillRegisteredRequest,
        connectionID: UUID,
        fd: Int32,
        dependencies: Dependencies
    ) async throws {
        if try await dependencies.registry.complete(
            requestID: request.requestID,
            connectionID: connectionID
        ) {
            if let completionGate = dependencies.completionGate { await completionGate() }
            try await delivery.release.deliver(delivery.value, toFileDescriptor: fd)
        } else if await dependencies.registry.terminalResult(for: request.requestID) == .timedOut {
            try? writeFailure(.expired, requestID: request.requestID, to: fd)
        }
    }

    private static func beginCredentialRequest(
        _ resolution: AutoFillCredentialResolution,
        admission: Admission,
        registry: AutoFillRequestRegistry
    ) async throws -> AutoFillRegisteredRequest {
        let request = try await registry.begin(
            requestID: resolution.requestID,
            descriptorID: resolution.descriptorID,
            kind: resolution.kind,
            deadline: admission.deadline
        )
        try await registry.bindConnection(requestID: request.requestID, connectionID: admission.connectionID)
        try await registry.transition(requestID: request.requestID, to: .connecting)
        return request
    }

    /// Binds only an authenticated connection and clears bootstrap admission
    /// only after its nonce was atomically consumed by the registry.
    private static func bindAdmission(
        _ admission: Admission,
        dependencies: Dependencies
    ) async throws -> Bool {
        guard admission.wakeHandle != nil
                || dependencies.launchGate.requiresInitialClaim(at: DispatchTime.now().uptimeNanoseconds) == false else {
            return false
        }
        do {
            try await dependencies.registry.bindVerifiedConnection(
                admission.connectionID,
                peer: admission.peer,
                wakeHandle: admission.wakeHandle,
                requestDeadline: admission.deadline
            )
        } catch AutoFillRequestRegistry.Error.invalidWakeClaim {
            return false
        }
        if let wakeHandle = admission.wakeHandle {
            dependencies.launchGate.completeInitialClaim(handle: wakeHandle, deadline: admission.deadline)
        }
        return true
    }

    private static func requestDeadlineIsValid(_ deadline: UInt64) -> Bool {
        let current = DispatchTime.now().uptimeNanoseconds
        guard deadline > current else { return false }
        let (maximumDeadline, overflow) = current.addingReportingOverflow(
            maximumRequestLifetimeNanoseconds
        )
        return overflow == false && deadline <= maximumDeadline
    }

    private static func resolveWhileConnected<Value: Sendable>(
        fd: Int32,
        deadline: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    guard DispatchTime.now().uptimeNanoseconds < deadline else {
                        throw AutoFillBrokerCoordinator.Error.deadlineExpired
                    }
                    var byte: UInt8 = 0
                    let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                    if result == 0 { throw AutoFillBrokerError.disconnected }
                    if result < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                        throw AutoFillBrokerError.disconnected
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private static func writeFailure(
        _ failure: AutoFillBrokerFailure,
        requestID: UUID,
        to fd: Int32
    ) throws {
        try AutoFillWire.writeMessage(
            AutoFillBrokerResponse.failure(requestID: requestID, failure: failure),
            toFileDescriptor: fd
        )
    }
}
