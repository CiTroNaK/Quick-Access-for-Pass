import Darwin
import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill broker client", .serialized)
struct AutoFillBrokerClientTests {
    @Test("verifies the host before sending the narrow request")
    func verifiesBeforeSending() async throws {
        let descriptorID = UUID()
        let clock = UInt64(1_000_000_000)
        let deadline = clock + 2_000_000_000
        let connection = FakeAutoFillClientConnection(responseValue: "fake-password")
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: { connection },
            hostOpener: opener,
            retryDelay: .milliseconds(1),
            now: { clock }
        )

        let value = try await client.resolve(
            descriptorID: descriptorID,
            kind: .password,
            deadline: deadline,
            appAssociationIntent: nil
        )

        #expect(value == "fake-password")
        let events = connection.recordedEvents()
        #expect(events.map(\.name) == ["verify", "exchange", "close"])
        let request = try #require(events.compactMap(\.request).first)
        #expect(request.descriptorID == descriptorID)
        #expect(request.valueKind == .password)
        #expect(request.deadlineUptimeNanoseconds == deadline)
        #expect(request.wakeHandle == nil)
        #expect(await opener.handles().isEmpty)
    }

    @Test("verified unauthorized response without this client's wake fails immediately")
    func unauthorizedWithoutOwnWakeIsNotRetried() async {
        let connection = FakeAutoFillClientConnection(responseFailure: .unauthorized)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: {
                attempts.withLock { $0 += 1 }
                return connection
            },
            hostOpener: opener,
            retryDelay: .milliseconds(1)
        )

        await #expect(throws: AutoFillBrokerClientError.unauthorized) {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            appAssociationIntent: nil
            )
        }
        #expect(attempts.withLock { $0 } == 1)
        #expect(connection.exchangeCount() == 1)
        #expect(await opener.handles().isEmpty)
    }

    @Test("verified unauthorized wake response retries after delayed host registration")
    func delayedWakeRegistrationRetries() async throws {
        let clock = UInt64(1_000_000_000)
        let registry = AutoFillRequestRegistry(now: { clock })
        let firstConnectionID = UUID()
        let secondConnectionID = UUID()
        try await registry.bindConnection(firstConnectionID, peer: verifiedExtensionPeer())
        try await registry.bindConnection(secondConnectionID, peer: verifiedExtensionPeer())
        defer {
            Task {
                await registry.removeConnection(firstConnectionID)
                await registry.removeConnection(secondConnectionID)
            }
        }

        let first = RegistryBackedAutoFillClientConnection(
            registry: registry,
            connectionID: firstConnectionID,
            responseValue: "must-not-resolve"
        )
        let second = RegistryBackedAutoFillClientConnection(
            registry: registry,
            connectionID: secondConnectionID,
            responseValue: "resolved-after-registration"
        )
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let sleepCalls = OSAllocatedUnfairLock(initialState: 0)
        let opener = RecordingAutoFillHostOpener()
        let deadline = clock + 2_000_000_000
        let client = AutoFillBrokerClient(
            connectionFactory: {
                try attempts.withLock { count in
                    count += 1
                    switch count {
                    case 1: throw AutoFillBrokerClientError.unavailable
                    case 2: return first
                    default: return second
                    }
                }
            },
            hostOpener: opener,
            retryDelay: .milliseconds(1),
            now: { clock },
            sleep: { _ in
                let call = sleepCalls.withLock { count in
                    count += 1
                    return count
                }
                guard call == 2 else { return }
                guard let handle = await opener.handles().first else {
                    throw DelayedWakeTestError.missingHandle
                }
                try await registry.registerWake(handle: handle, deadline: deadline)
            }
        )

        let value = try await client.resolve(
            descriptorID: UUID(),
            kind: .password,
            deadline: deadline,
            appAssociationIntent: nil
        )

        #expect(value == "resolved-after-registration")
        #expect(attempts.withLock { $0 } == 3)
        #expect(sleepCalls.withLock { $0 } == 2)
        #expect(await opener.handles().count == 1)
        #expect(first.claimResults() == [false])
        #expect(second.claimResults() == [true])
        let firstRequest = try #require(first.requests().first)
        let secondRequest = try #require(second.requests().first)
        #expect(firstRequest.requestID == secondRequest.requestID)
        #expect(firstRequest.deadlineUptimeNanoseconds == deadline)
        #expect(secondRequest.deadlineUptimeNanoseconds == deadline)
        #expect(firstRequest.wakeHandle == secondRequest.wakeHandle)
    }

    @Test("permanently missing wake handle retries only until the original deadline")
    func permanentlyMissingWakeHandleIsBounded() async {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let sleepCalls = OSAllocatedUnfairLock(initialState: 0)
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: {
                let attempt = attempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 { throw AutoFillBrokerClientError.unavailable }
                return FakeAutoFillClientConnection(responseFailure: .unauthorized)
            },
            hostOpener: opener,
            retryDelay: .milliseconds(1),
            now: { clock.withLock { $0 } },
            sleep: { _ in
                sleepCalls.withLock {
                    $0 += 1
                    clock.withLock { $0 += 250_000_000 }
                }
            }
        )

        await #expect(throws: AutoFillBrokerClientError.expired) {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: 2_000_000_000,
            appAssociationIntent: nil
            )
        }
        #expect(attempts.withLock { $0 } == 4)
        #expect(sleepCalls.withLock { $0 } == 4)
        #expect(await opener.handles().count == 1)
    }

    @Test(
        "host signing and peer lookup failures after wake fail immediately without retry",
        arguments: [
            AutoFillPeerVerificationError.invalidPeer,
            AutoFillPeerVerificationError.guestLookupFailed(-1),
        ]
    )
    func postWakePeerFailureIsNotRetried(error: AutoFillPeerVerificationError) async {
        let connection = FakeAutoFillClientConnection(peerVerificationError: error)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let sleepCalls = OSAllocatedUnfairLock(initialState: 0)
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: {
                let attempt = attempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 { throw AutoFillBrokerClientError.unavailable }
                return connection
            },
            hostOpener: opener,
            retryDelay: .milliseconds(1),
            sleep: { _ in sleepCalls.withLock { $0 += 1 } }
        )

        await #expect(throws: AutoFillBrokerClientError.unauthorized) {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            appAssociationIntent: nil
            )
        }
        #expect(attempts.withLock { $0 } == 2)
        #expect(sleepCalls.withLock { $0 } == 1)
        #expect(connection.exchangeCount() == 0)
        #expect(await opener.handles().count == 1)
    }

    @Test(
        "internal peer verifier failures retain their error",
        arguments: [
            AutoFillPeerVerificationError.peerTokenUnavailable,
            AutoFillPeerVerificationError.invalidAuditToken,
            AutoFillPeerVerificationError.invalidExpectedIdentity,
        ]
    )
    func internalPeerFailurePropagates(error: AutoFillPeerVerificationError) async {
        let connection = FakeAutoFillClientConnection(peerVerificationError: error)
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: { connection },
            hostOpener: opener,
            retryDelay: .milliseconds(1)
        )

        await #expect(throws: error) {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
                appAssociationIntent: nil
            )
        }
        #expect(connection.exchangeCount() == 0)
        #expect(await opener.handles().isEmpty)
    }

    @Test("unavailable broker launches once with a random handle and retries until the original deadline")
    func unavailableLaunchesAndRetries() async throws {
        let second = FakeAutoFillClientConnection(responseValue: "654321")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let opener = RecordingAutoFillHostOpener()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let client = AutoFillBrokerClient(
            connectionFactory: {
                try attempts.withLock { count in
                    count += 1
                    if count == 1 { throw AutoFillBrokerClientError.unavailable }
                    return second
                }
            },
            hostOpener: opener,
            retryDelay: .milliseconds(1)
        )

        let value = try await client.resolve(
            descriptorID: UUID(),
            kind: .oneTimeCode,
            deadline: deadline,
            appAssociationIntent: nil
        )

        #expect(value == "654321")
        let handles = await opener.handles()
        let handle = try #require(handles.first)
        #expect(handles.count == 1)
        let request = try #require(second.recordedEvents().compactMap(\.request).first)
        #expect(request.wakeHandle == handle)
        #expect(request.deadlineUptimeNanoseconds == deadline)
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test("unavailable broker retries only until the original deadline and opens once")
    func unavailableStopsAtDeadline() async {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(100))
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: {
                attempts.withLock { $0 += 1 }
                throw AutoFillBrokerClientError.unavailable
            },
            hostOpener: opener,
            retryDelay: .nanoseconds(10),
            now: { clock.withLock { $0 } },
            sleep: { _ in clock.withLock { $0 = 200 } }
        )

        await #expect(throws: AutoFillBrokerClientError.expired) {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: 200,
            appAssociationIntent: nil
            )
        }
        #expect(attempts.withLock { $0 } == 1)
        #expect(await opener.handles().count == 1)
    }

    @Test("hanging host opener expires at the original deadline and ignores a late callback")
    @MainActor
    func hangingOpenerExpiresWithoutOrphan() async throws {
        let opener = ControlledAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: { throw AutoFillBrokerClientError.unavailable },
            hostOpener: opener,
            retryDelay: .milliseconds(1)
        )
        let start = ContinuousClock.now
        let task = Task {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: DispatchTime.now().uptimeNanoseconds + 200_000_000,
            appAssociationIntent: nil
            )
        }
        #expect(await waitUntil { await opener.isActive })

        await #expect(throws: AutoFillBrokerClientError.expired) { try await task.value }

        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(opener.isActive == false)
        #expect(opener.cancellationCount == 1)
        opener.complete(true)
        #expect(opener.acceptedCompletionCount == 0)
        #expect(opener.ignoredCompletionCount == 1)
    }

    @Test("cancellation returns promptly while host opener hangs and late callback is ignored")
    @MainActor
    func cancellationDrainsHangingOpener() async throws {
        let opener = ControlledAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: { throw AutoFillBrokerClientError.unavailable },
            hostOpener: opener,
            retryDelay: .milliseconds(1)
        )
        let task = Task {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000,
            appAssociationIntent: nil
            )
        }
        #expect(await waitUntil { await opener.isActive })

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(opener.isActive == false)
        #expect(opener.cancellationCount == 1)
        opener.complete(true)
        #expect(opener.acceptedCompletionCount == 0)
        #expect(opener.ignoredCompletionCount == 1)
    }

    @Test("peer verification failure sends no bytes and never launches the host")
    func verificationFailureIsNotAvailability() async {
        let connection = FakeAutoFillClientConnection(verificationError: .unauthorized)
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: { connection },
            hostOpener: opener,
            retryDelay: .milliseconds(1)
        )

        await #expect(throws: AutoFillBrokerClientError.unauthorized) {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            appAssociationIntent: nil
            )
        }
        #expect(connection.recordedEvents().contains { $0.name == "exchange" } == false)
        #expect(await opener.handles().isEmpty)
    }

    @Test("unknown or stale descriptor fails once without launch or fallback search")
    func staleDescriptorDoesNotFallback() async {
        let connection = FakeAutoFillClientConnection(responseFailure: .resolutionFailed)
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            connectionFactory: { connection },
            hostOpener: opener,
            retryDelay: .milliseconds(1)
        )

        await #expect(throws: AutoFillBrokerClientError.brokerFailure(.resolutionFailed)) {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            appAssociationIntent: nil
            )
        }
        #expect(connection.exchangeCount() == 1)
        #expect(await opener.handles().isEmpty)
    }

    @Test("cancellation closes the active socket and stops retries")
    @MainActor
    func cancellationClosesSocket() async throws {
        let connection = FakeAutoFillClientConnection(connectionError: .unavailable)
        let queue = ConnectionQueue([connection])
        let opener = ControlledAutoFillHostOpener()
        let retryDelay = ControlledAutoFillRetryDelay()
        let client = AutoFillBrokerClient(
            connectionFactory: { try queue.next() },
            hostOpener: opener,
            retryDelay: .milliseconds(1),
            sleep: { _ in try await retryDelay.sleep() }
        )
        let task = Task {
            try await client.resolve(
                descriptorID: UUID(),
                kind: .password,
                deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000,
                appAssociationIntent: nil
            )
        }
        #expect(await waitUntil { await opener.isActive })
        opener.complete(true)
        #expect(await waitUntil { retryDelay.isSleeping() })

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(opener.openCount == 1)
        #expect(connection.closeCount() == 1)
        #expect(queue.callCount() == 1)
    }

    @Test("production socket exchange authenticates before the fake host receives bytes")
    func productionSocketExchange() async throws {
        let fixture = try ClientSocketFixture()
        defer { fixture.cleanup() }
        let verified = OSAllocatedUnfairLock(initialState: false)
        let observed = OSAllocatedUnfairLock(initialState: Optional<AutoFillBrokerRequest>.none)
        let server = fixture.startServer { request in
            observed.withLock { $0 = request }
            return .credential(requestID: request.requestID, value: "socket-value")
        }
        let opener = RecordingAutoFillHostOpener()
        let client = AutoFillBrokerClient(
            socketPath: fixture.socketPath,
            hostOpener: opener,
            verifier: { fd in
                verified.withLock { $0 = true }
                return VerifiedAutoFillPeer(
                    fileDescriptor: fd,
                    identifier: AutoFillConstants.hostBundleIdentifier,
                    teamID: "H23TXL6LPT"
                )
            },
            retryDelay: .milliseconds(1)
        )

        let value = try await client.resolve(
            descriptorID: UUID(),
            kind: .password,
            deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000,
            appAssociationIntent: nil
        )
        _ = try await server.value

        #expect(value == "socket-value")
        #expect(verified.withLock { $0 })
        #expect(observed.withLock { $0 } != nil)
    }

    private func verifiedExtensionPeer() -> VerifiedAutoFillPeer {
        VerifiedAutoFillPeer(
            fileDescriptor: 1,
            identifier: AutoFillConstants.extensionBundleIdentifier,
            teamID: "H23TXL6LPT"
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

extension AutoFillBrokerClientTests {
    @Test("candidate listing wakes the host, retries, and returns only matching response metadata")
    func candidateListingWakesAndRetries() async throws {
        let expected = [
            AutoFillCandidate(
                descriptorID: UUID(),
                title: "Example",
                username: "person@example.com",
                kind: .password,
                matchTier: 0
            )
        ]
        let connection = FakeAutoFillClientConnection(responseCandidates: expected)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let opener = RecordingAutoFillHostOpener()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let client = AutoFillBrokerClient(
            connectionFactory: {
                let attempt = attempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 { throw AutoFillBrokerClientError.unavailable }
                return connection
            },
            hostOpener: opener,
            retryDelay: .milliseconds(1)
        )
        let query = AutoFillCandidateQuery.global(
            requestID: UUID(),
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: deadline
        )

        let candidates = try await client.listCandidates(query, deadline: deadline)

        #expect(candidates == expected)
        #expect(attempts.withLock { $0 } == 2)
        #expect(await opener.handles().count == 1)
        let handle = try #require(await opener.handles().first)
        let request = try #require(connection.recordedEvents().compactMap(\.request).first)
        #expect(request == .listCandidates(.global(
            requestID: query.requestID,
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: deadline,
            wakeHandle: handle
        )))
    }

    @Test("candidate listing rejects a mismatched response ID and excessive candidate count")
    func candidateListingRejectsInvalidResponses() async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        let query = AutoFillCandidateQuery.global(
            requestID: UUID(),
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: deadline
        )
        let mismatched = FakeAutoFillClientConnection(
            responseCandidates: [],
            responseRequestID: UUID()
        )
        let oversized = FakeAutoFillClientConnection(
            responseCandidates: (0...AutoFillCandidate.maximumCandidates).map { index in
                AutoFillCandidate(
                    descriptorID: UUID(),
                    title: "Title \(index)",
                    username: "user\(index)",
                    kind: .password,
                    matchTier: 0
                )
            }
        )

        await #expect(throws: AutoFillBrokerClientError.invalidResponse) {
            try await AutoFillBrokerClient(
                connectionFactory: { mismatched },
                hostOpener: RecordingAutoFillHostOpener()
            ).listCandidates(query, deadline: deadline)
        }
        await #expect(throws: AutoFillBrokerClientError.invalidResponse) {
            try await AutoFillBrokerClient(
                connectionFactory: { oversized },
                hostOpener: RecordingAutoFillHostOpener()
            ).listCandidates(query, deadline: deadline)
        }
    }

    @Test("candidate listing maps broker failures and closes its socket on cancellation")
    func candidateListingFailureAndCancellation() async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let query = AutoFillCandidateQuery.global(
            requestID: UUID(),
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: deadline
        )
        let failing = FakeAutoFillClientConnection(responseFailure: .unavailable)
        await #expect(throws: AutoFillBrokerClientError.brokerFailure(.unavailable)) {
            try await AutoFillBrokerClient(
                connectionFactory: { failing },
                hostOpener: RecordingAutoFillHostOpener()
            ).listCandidates(query, deadline: deadline)
        }

        let blocking = FakeAutoFillClientConnection(blockUntilClosed: true)
        let client = AutoFillBrokerClient(
            connectionFactory: { blocking },
            hostOpener: RecordingAutoFillHostOpener()
        )
        let task = Task { try await client.listCandidates(query, deadline: deadline) }
        #expect(await waitUntil { blocking.exchangeCount() == 1 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(blocking.closeCount() == 1)
    }

}

private enum DelayedWakeTestError: Error {
    case missingHandle
}

private struct ClientEvent: Sendable {
    let name: String
    let request: AutoFillBrokerRequest?
}

private final class FakeAutoFillClientConnection: AutoFillBrokerClientConnection, Sendable {
    private struct State {
        var events: [ClientEvent] = []
        var isClosed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let responseValue: String?
    private let responseCandidates: [AutoFillCandidate]?
    private let responseRequestID: UUID?
    private let responseFailure: AutoFillBrokerFailure?
    private let verificationError: AutoFillBrokerClientError?
    private let peerVerificationError: AutoFillPeerVerificationError?
    private let connectionError: AutoFillBrokerClientError?
    private let blockUntilClosed: Bool

    init(
        responseValue: String? = nil,
        responseCandidates: [AutoFillCandidate]? = nil,
        responseRequestID: UUID? = nil,
        responseFailure: AutoFillBrokerFailure? = nil,
        verificationError: AutoFillBrokerClientError? = nil,
        peerVerificationError: AutoFillPeerVerificationError? = nil,
        connectionError: AutoFillBrokerClientError? = nil,
        blockUntilClosed: Bool = false
    ) {
        self.responseValue = responseValue
        self.responseCandidates = responseCandidates
        self.responseRequestID = responseRequestID
        self.responseFailure = responseFailure
        self.verificationError = verificationError
        self.peerVerificationError = peerVerificationError
        self.connectionError = connectionError
        self.blockUntilClosed = blockUntilClosed
    }

    func verifyHost() throws {
        state.withLock { $0.events.append(ClientEvent(name: "verify", request: nil)) }
        if let verificationError { throw verificationError }
        if let peerVerificationError { throw peerVerificationError }
    }

    func exchange(_ request: AutoFillBrokerRequest) throws -> AutoFillBrokerResponse {
        state.withLock { $0.events.append(ClientEvent(name: "exchange", request: request)) }
        if let connectionError { throw connectionError }
        if blockUntilClosed {
            while state.withLock({ !$0.isClosed }) {
                usleep(1_000)
            }
            throw CancellationError()
        }
        let responseID = responseRequestID ?? request.requestID
        if let responseFailure {
            return .failure(requestID: responseID, failure: responseFailure)
        }
        if let responseCandidates {
            return .candidates(requestID: responseID, candidates: responseCandidates)
        }
        return .credential(requestID: responseID, value: responseValue ?? "value")
    }

    func close() {
        state.withLock {
            guard !$0.isClosed else { return }
            $0.isClosed = true
            $0.events.append(ClientEvent(name: "close", request: nil))
        }
    }

    func recordedEvents() -> [ClientEvent] { state.withLock(\.events) }
    func exchangeCount() -> Int { state.withLock { $0.events.filter { $0.name == "exchange" }.count } }
    func closeCount() -> Int { state.withLock { $0.events.filter { $0.name == "close" }.count } }
}

private final class RegistryBackedAutoFillClientConnection: AutoFillBrokerClientConnection, Sendable {
    private struct State {
        var requests: [AutoFillBrokerRequest] = []
        var claimResults: [Bool] = []
    }

    private let registry: AutoFillRequestRegistry
    private let connectionID: UUID
    private let responseValue: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        registry: AutoFillRequestRegistry,
        connectionID: UUID,
        responseValue: String
    ) {
        self.registry = registry
        self.connectionID = connectionID
        self.responseValue = responseValue
    }

    func verifyHost() throws {}

    func exchange(_ request: AutoFillBrokerRequest) throws -> AutoFillBrokerResponse {
        state.withLock { $0.requests.append(request) }
        guard let handle = request.wakeHandle else {
            return .failure(requestID: request.requestID, failure: .unauthorized)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let claim = OSAllocatedUnfairLock(initialState: false)
        let registry = registry
        let connectionID = connectionID
        Task.detached {
            let result = await registry.claimWake(handle: handle, connectionID: connectionID)
            claim.withLock { $0 = result }
            semaphore.signal()
        }
        semaphore.wait()
        let claimed = claim.withLock { $0 }
        state.withLock { $0.claimResults.append(claimed) }
        guard claimed else {
            return .failure(requestID: request.requestID, failure: .unauthorized)
        }
        return .credential(requestID: request.requestID, value: responseValue)
    }

    func close() {}

    func requests() -> [AutoFillBrokerRequest] { state.withLock(\.requests) }
    func claimResults() -> [Bool] { state.withLock(\.claimResults) }
}

private final class ConnectionQueue: Sendable {
    private let state: OSAllocatedUnfairLock<(connections: [any AutoFillBrokerClientConnection], calls: Int)>

    init(_ connections: [any AutoFillBrokerClientConnection]) {
        state = OSAllocatedUnfairLock(initialState: (connections, 0))
    }

    func next() throws -> any AutoFillBrokerClientConnection {
        try state.withLock {
            $0.calls += 1
            guard !$0.connections.isEmpty else { throw AutoFillBrokerClientError.unavailable }
            return $0.connections.removeFirst()
        }
    }

    func callCount() -> Int { state.withLock { $0.calls } }
}

private final class ControlledAutoFillRetryDelay: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var isSleeping = false
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func sleep() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = state.withLock { state in
                    guard state.isCancelled == false else { return true }
                    state.continuation = continuation
                    state.isSleeping = true
                    return false
                }
                if shouldCancel { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.isCancelled = true
                state.isSleeping = false
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func isSleeping() -> Bool { state.withLock(\.isSleeping) }
}

@MainActor
private final class RecordingAutoFillHostOpener: AutoFillHostOpening {
    private var openedHandles: [UUID] = []

    func open(handle: UUID) async -> Bool {
        openedHandles.append(handle)
        return true
    }

    func handles() -> [UUID] { openedHandles }
}

@MainActor
private final class ControlledAutoFillHostOpener: AutoFillHostOpening {
    private var continuation: CheckedContinuation<Bool, any Error>?
    private(set) var isActive = false
    private(set) var openCount = 0
    private(set) var cancellationCount = 0
    private(set) var acceptedCompletionCount = 0
    private(set) var ignoredCompletionCount = 0

    func open(handle: UUID) async throws -> Bool {
        openCount += 1
        isActive = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor in self.cancelOpen() }
        }
    }

    func complete(_ value: Bool) {
        guard let continuation else {
            ignoredCompletionCount += 1
            return
        }
        self.continuation = nil
        isActive = false
        acceptedCompletionCount += 1
        continuation.resume(returning: value)
    }

    private func cancelOpen() {
        guard let continuation else { return }
        self.continuation = nil
        isActive = false
        cancellationCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

private final class ClientSocketFixture {
    let rootURL: URL
    let socketPath: String
    private let listener: Int32

    init() throws {
        rootURL = URL(fileURLWithPath: "/tmp/qafc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        socketPath = rootURL.appendingPathComponent("broker.sock").path
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = makeAddress(path: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(listener, 1) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
    }

    func startServer(
        handler: @escaping @Sendable (AutoFillBrokerRequest) throws -> AutoFillBrokerResponse
    ) -> Task<Void, any Error> {
        let listener = listener
        return Task.detached {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { throw POSIXError(.ECONNABORTED) }
            defer { close(fd) }
            let request = try AutoFillWire.readMessage(AutoFillBrokerRequest.self, fromFileDescriptor: fd)
            try AutoFillWire.writeMessage(try handler(request), toFileDescriptor: fd)
        }
    }

    func cleanup() {
        close(listener)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func makeAddress(path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8) + [0]
            buffer.copyBytes(from: bytes.prefix(buffer.count))
        }
        return address
    }
}
