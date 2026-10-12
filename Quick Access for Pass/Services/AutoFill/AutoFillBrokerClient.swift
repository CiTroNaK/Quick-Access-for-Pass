import Foundation
import os

nonisolated enum AutoFillBrokerClientError: Error, Equatable, Sendable {
    case unavailable
    case unauthorized
    case expired
    case invalidResponse
    case brokerFailure(AutoFillBrokerFailure)
}

nonisolated protocol AutoFillBrokerListing: Sendable {
    func listCandidates(
        _ query: AutoFillCandidateQuery,
        deadline: UInt64
    ) async throws -> [AutoFillCandidate]
}

nonisolated protocol AutoFillBrokerResolving: Sendable {
    func resolve(
        descriptorID: UUID,
        kind: AutoFillValueKind,
        deadline: UInt64,
        appAssociationIntent: AutoFillAppAssociationIntent?
    ) async throws -> String
}

/// Main-actor boundary for the extension's nonactivating host wake request.
/// The launch handle is random metadata and does not authorize a credential request.
@MainActor
protocol AutoFillHostOpening: Sendable {
    func open(handle: UUID) async throws -> Bool
}

/// Injectable connection boundary used to prove verification occurs before any frame is sent.
nonisolated protocol AutoFillBrokerClientConnection: AnyObject, Sendable {
    func verifyHost() throws
    func exchange(_ request: AutoFillBrokerRequest) throws -> AutoFillBrokerResponse
    func close()
}

/// Extension-side client for the dedicated broker. A single monotonic deadline
/// covers host wake, mutually verified connection, and broker resolution.
nonisolated final class AutoFillBrokerClient: AutoFillBrokerListing, AutoFillBrokerResolving, Sendable {
    typealias ConnectionFactory = @Sendable () throws -> any AutoFillBrokerClientConnection
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let connectionFactory: ConnectionFactory
    private let hostOpener: any AutoFillHostOpening
    private let retryDelay: Duration
    private let now: @Sendable () -> UInt64
    private let sleep: Sleep
    private let deadlineSleep: Sleep

    // A substituted clock must also supply its watchdog sleeper. Retry pacing
    // remains separate so immediate test retries cannot expire host-opening work.
    init(
        connectionFactory: @escaping ConnectionFactory,
        hostOpener: any AutoFillHostOpening,
        retryDelay: Duration = .milliseconds(50),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        deadlineSleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.connectionFactory = connectionFactory
        self.hostOpener = hostOpener
        self.retryDelay = retryDelay
        self.now = now
        self.sleep = sleep
        self.deadlineSleep = deadlineSleep
    }

    convenience init(
        socketPath: String,
        hostOpener: any AutoFillHostOpening,
        verifier: @escaping @Sendable (Int32) throws -> VerifiedAutoFillPeer = { fd in
            try AutoFillPeerVerifier.verify(
                fd: fd,
                expectedIdentifier: AutoFillConstants.hostBundleIdentifier,
                teamID: "H23TXL6LPT"
            )
        },
        retryDelay: Duration = .milliseconds(50)
    ) {
        self.init(
            connectionFactory: {
                try SocketAutoFillBrokerClientConnection(
                    socketPath: socketPath,
                    verifier: verifier
                )
            },
            hostOpener: hostOpener,
            retryDelay: retryDelay
        )
    }

    convenience init(hostOpener: any AutoFillHostOpening) throws {
        try self.init(
            socketPath: AutoFillConstants.brokerSocketURL().path,
            hostOpener: hostOpener
        )
    }

    func resolve(
        descriptorID: UUID,
        kind: AutoFillValueKind,
        deadline: UInt64,
        appAssociationIntent: AutoFillAppAssociationIntent?
    ) async throws -> String {
        let requestID = UUID()
        return try await perform(
            requestID: requestID,
            deadline: deadline,
            makeRequest: { wakeHandle in
                .resolveCredential(
                    requestID: requestID,
                    descriptorID: descriptorID,
                    valueKind: kind,
                    deadlineUptimeNanoseconds: deadline,
                    wakeHandle: wakeHandle,
                    appAssociationIntent: appAssociationIntent
                )
            },
            handleResponse: { response in
                switch response {
                case .credential(let responseID, let value) where responseID == requestID:
                    return value
                case .failure(let responseID, let failure) where responseID == requestID:
                    if failure == .cancelled { throw CancellationError() }
                    throw Self.error(for: failure)
                default:
                    throw AutoFillBrokerClientError.invalidResponse
                }
            }
        )
    }

    func listCandidates(
        _ query: AutoFillCandidateQuery,
        deadline: UInt64
    ) async throws -> [AutoFillCandidate] {
        guard query.deadlineUptimeNanoseconds == deadline else {
            throw AutoFillBrokerClientError.invalidResponse
        }
        let requestID = query.requestID
        return try await perform(
            requestID: requestID,
            deadline: deadline,
            makeRequest: { wakeHandle in
                switch query {
                case .site(_, let services, let kind, _, _):
                    return .listCandidates(.site(
                        requestID: requestID,
                        services: services,
                        kind: kind,
                        deadlineUptimeNanoseconds: deadline,
                        wakeHandle: wakeHandle
                    ))
                case .global(_, let search, let kind, _, _):
                    return .listCandidates(.global(
                        requestID: requestID,
                        search: search,
                        kind: kind,
                        deadlineUptimeNanoseconds: deadline,
                        wakeHandle: wakeHandle
                    ))
                }
            },
            handleResponse: { response in
                switch response {
                case .candidates(let responseID, let candidates) where responseID == requestID:
                    guard candidates.count <= AutoFillCandidate.maximumCandidates else {
                        throw AutoFillBrokerClientError.invalidResponse
                    }
                    return candidates
                case .failure(let responseID, let failure) where responseID == requestID:
                    if failure == .cancelled { throw CancellationError() }
                    throw Self.error(for: failure)
                default:
                    throw AutoFillBrokerClientError.invalidResponse
                }
            }
        )
    }

    private static func error(for failure: AutoFillBrokerFailure) -> AutoFillBrokerClientError {
        switch failure {
        case .expired:
            return .expired
        case .unauthorized:
            return .unauthorized
        default:
            return .brokerFailure(failure)
        }
    }

    private static func error(for failure: AutoFillPeerVerificationError) -> any Error {
        switch failure {
        case .invalidPeer, .guestLookupFailed, .requirementCreationFailed:
            return AutoFillBrokerClientError.unauthorized
        case .invalidExpectedIdentity, .peerTokenUnavailable, .invalidAuditToken:
            return failure
        }
    }

    private func perform<Result: Sendable>(
        requestID: UUID,
        deadline: UInt64,
        makeRequest: @escaping @Sendable (UUID?) -> AutoFillBrokerRequest,
        handleResponse: @escaping @Sendable (AutoFillBrokerResponse) throws -> Result
    ) async throws -> Result {
        let attemptState = AutoFillClientAttemptState()

        return try await withTaskCancellationHandler {
            var wakeHandle: UUID?
            var didRequestHostWake = false

            while true {
                try Task.checkCancellation()
                guard now() < deadline else { throw AutoFillBrokerClientError.expired }

                do {
                    let response = try await performAttempt(
                        attemptState: attemptState,
                        wakeHandle: wakeHandle,
                        makeRequest: makeRequest
                    )
                    guard now() < deadline else { throw AutoFillBrokerClientError.expired }
                    do {
                        return try handleResponse(response)
                    } catch AutoFillBrokerClientError.unauthorized {
                        guard didRequestHostWake, wakeHandle != nil else {
                            throw AutoFillBrokerClientError.unauthorized
                        }
                        try await sleepBeforeRetry(deadline: deadline)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch AutoFillBrokerClientError.unavailable {
                    attemptState.closeCurrent()
                    if didRequestHostWake == false {
                        let handle = UUID()
                        guard try await openHost(handle: handle, deadline: deadline) else {
                            throw AutoFillBrokerClientError.unavailable
                        }
                        wakeHandle = handle
                        didRequestHostWake = true
                    }
                    try await sleepBeforeRetry(deadline: deadline)
                } catch let error as AutoFillPeerVerificationError {
                    throw Self.error(for: error)
                }
            }
        } onCancel: {
            attemptState.cancel()
        }
    }

    private func performAttempt(
        attemptState: AutoFillClientAttemptState,
        wakeHandle: UUID?,
        makeRequest: @escaping @Sendable (UUID?) -> AutoFillBrokerRequest
    ) async throws -> AutoFillBrokerResponse {
        let connection = try connectionFactory()
        guard attemptState.install(connection) else {
            connection.close()
            throw CancellationError()
        }
        defer { attemptState.clearAndClose(connection) }

        do {
            let request = makeRequest(wakeHandle)
            return try await Task.detached(priority: .userInitiated) {
                try connection.verifyHost()
                return try connection.exchange(request)
            }.value
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func openHost(handle: UUID, deadline: UInt64) async throws -> Bool {
        let current = now()
        guard deadline > current else { throw AutoFillBrokerClientError.expired }
        let remaining = Duration.nanoseconds(Int64(min(deadline - current, UInt64(Int64.max))))
        let hostOpener = hostOpener
        let deadlineSleep = deadlineSleep

        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await hostOpener.open(handle: handle) }
            group.addTask {
                try await deadlineSleep(remaining)
                throw AutoFillBrokerClientError.expired
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }

    private func sleepBeforeRetry(deadline: UInt64) async throws {
        let current = now()
        guard deadline > current else { throw AutoFillBrokerClientError.expired }
        let remaining = Duration.nanoseconds(Int64(min(deadline - current, UInt64(Int64.max))))
        try await sleep(min(retryDelay, remaining))
    }
}

nonisolated private final class AutoFillClientAttemptState: Sendable {
    private struct State {
        var isCancelled = false
        var connection: (any AutoFillBrokerClientConnection)?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func install(_ connection: any AutoFillBrokerClientConnection) -> Bool {
        lock.withLock {
            guard $0.isCancelled == false else { return false }
            $0.connection = connection
            return true
        }
    }

    func clearAndClose(_ connection: any AutoFillBrokerClientConnection) {
        let shouldClose = lock.withLock { state in
            guard let current = state.connection, current === connection else { return false }
            state.connection = nil
            return true
        }
        if shouldClose { connection.close() }
    }

    func closeCurrent() {
        let connection = lock.withLock { state in
            let connection = state.connection
            state.connection = nil
            return connection
        }
        connection?.close()
    }

    func cancel() {
        let connection = lock.withLock { state in
            state.isCancelled = true
            let connection = state.connection
            state.connection = nil
            return connection
        }
        connection?.close()
    }
}
