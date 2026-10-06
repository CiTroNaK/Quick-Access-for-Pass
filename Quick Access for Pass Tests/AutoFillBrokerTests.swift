import Darwin
import Foundation
import Synchronization
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill host broker", .serialized)
struct AutoFillBrokerTests {
    @Test("partial nonblocking credential delivery leaves the descriptor for its owner")
    func partialNonblockingCredentialDeliveryPreservesOwnerFD() throws {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        defer { close(pair[0]); close(pair[1]) }
        var sendBuffer: Int32 = 1024
        guard setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        let initialFlags = fcntl(pair[0], F_GETFL, 0)
        guard initialFlags >= 0, fcntl(pair[0], F_SETFL, initialFlags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        let ownedFlags = fcntl(pair[0], F_GETFL, 0)
        let response = AutoFillBrokerResponse.credential(
            requestID: UUID(), value: String(repeating: "x", count: AutoFillWire.maximumMessageSize - 256)
        )

        #expect(throws: AutoFillWireDeliveryError.partialFrame) {
            try AutoFillWire.writeMessageNonblocking(response, toFileDescriptor: pair[0])
        }
        #expect(fcntl(pair[0], F_GETFD) >= 0)
        #expect(fcntl(pair[0], F_GETFL, 0) == ownedFlags)
    }

    @Test("listener creates owner-only directory and socket and survives independent requests")
    func permissionsAndPersistentListener() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let broker = fixture.makeBroker { request, _ in
            request.kind == .password ? "password-value" : "654321"
        }
        try await broker.start()
        defer { Task { await broker.stop() } }

        #expect(try permissions(at: fixture.directoryPath) == 0o700)
        #expect(try permissions(at: fixture.socketPath) == 0o600)

        let firstStartedAt = DispatchTime.now().uptimeNanoseconds
        let first = try await request(at: fixture.socketPath, kind: .password)
        guard case .credential(_, let firstValue) = first else {
            Issue.record("Unexpected first response category: \(responseCategory(first)); elapsed nanoseconds: \(DispatchTime.now().uptimeNanoseconds - firstStartedAt)")
            return
        }
        #expect(firstValue == "password-value")

        let secondStartedAt = DispatchTime.now().uptimeNanoseconds
        let second = try await request(at: fixture.socketPath, kind: .oneTimeCode)
        guard case .credential(_, let secondValue) = second else {
            Issue.record("Unexpected second response category: \(responseCategory(second)); elapsed nanoseconds: \(DispatchTime.now().uptimeNanoseconds - secondStartedAt)")
            return
        }
        #expect(secondValue == "654321")
    }

    @Test("peer verification happens before request framing and rejection invokes no handler")
    func verificationBeforeRead() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let verifierCalls = OSAllocatedUnfairLock(initialState: 0)
        let frameWasUnread = OSAllocatedUnfairLock(initialState: false)
        let handlerCalls = OSAllocatedUnfairLock(initialState: 0)
        let broker = fixture.makeBroker(
            verifier: { fd in
                verifierCalls.withLock { $0 += 1 }
                var byte: UInt8 = 0
                let result = Darwin.recv(fd, &byte, 1, MSG_PEEK)
                let observedMalformedHeader = result == 1 && byte == 0
                frameWasUnread.withLock { $0 = observedMalformedHeader }
                throw AutoFillPeerVerificationError.invalidPeer
            },
            handler: { _, _ in
                handlerCalls.withLock { $0 += 1 }
                return "must-not-run"
            }
        )
        try await broker.start()
        defer { Task { await broker.stop() } }

        let fd = try Self.connect(to: fixture.socketPath)
        defer { close(fd) }
        var malformedLength = UInt32(0).bigEndian
        let written = withUnsafeBytes(of: &malformedLength) { buffer in
            Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
        guard written == MemoryLayout<UInt32>.size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
        }
        var byte: UInt8 = 0
        let readResult = Darwin.read(fd, &byte, 1)

        #expect(readResult == 0 || (readResult == -1 && errno != EINTR))
        #expect(verifierCalls.withLock { $0 } == 1)
        #expect(frameWasUnread.withLock { $0 })
        #expect(handlerCalls.withLock { $0 } == 0)
    }

    @Test("accepted connections remain bounded while a request handler is active")
    func boundedConnections() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let handler = CapacityBlockingCandidateHandler()
        let broker = fixture.makeBroker(
            maximumConnections: 1,
            idleTimeout: 0.05,
            handler: { _, _ in "must-not-resolve" },
            candidateHandler: { query in await handler.resolve(query) }
        )
        try await broker.start()
        defer { Task { await broker.stop() } }

        let activeFD = try Self.connect(to: fixture.socketPath)
        defer { close(activeFD) }
        let query = AutoFillCandidateQuery.global(
            requestID: UUID(),
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        )
        try AutoFillWire.writeMessage(AutoFillBrokerRequest.listCandidates(query), toFileDescriptor: activeFD)
        #expect(await waitUntil { await handler.hasStarted() })
        #expect(await broker.activeConnectionCount() == 1)

        let rejectedFD = try Self.connect(to: fixture.socketPath)
        defer { close(rejectedFD) }
        try? AutoFillWire.writeMessage(makeWireRequest(kind: .password), toFileDescriptor: rejectedFD)
        var byte: UInt8 = 0
        #expect(Darwin.read(rejectedFD, &byte, 1) <= 0)

        await handler.release()
        let response = try AutoFillWire.readMessage(AutoFillBrokerResponse.self, fromFileDescriptor: activeFD)
        guard case .candidates(let responseID, let candidates) = response else {
            Issue.record("Active request did not complete")
            return
        }
        #expect(responseID == query.requestID)
        #expect(candidates.isEmpty)
    }

    @Test("idle connections expire without stopping the listener")
    func idleConnectionsExpire() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let broker = fixture.makeBroker(maximumConnections: 1, idleTimeout: 0.05) { _, _ in "value" }
        try await broker.start()
        defer { Task { await broker.stop() } }

        let idleFD = try Self.connect(to: fixture.socketPath)
        defer { close(idleFD) }
        #expect(await waitUntil { await broker.activeConnectionCount() == 1 })
        #expect(await waitUntil(timeout: 1) { await broker.activeConnectionCount() == 0 })

        let response = try await request(at: fixture.socketPath, message: makeWireRequest(kind: .password))
        guard case .credential = response else { Issue.record("Listener did not accept a later request"); return }
    }

    @Test("stop closes accepted connections and removes the listener socket")
    func stopCleansLifecycle() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let broker = fixture.makeBroker(idleTimeout: 5) { _, _ in "value" }
        try await broker.start()
        let idleFD = try Self.connect(to: fixture.socketPath)
        defer { close(idleFD) }
        #expect(await waitUntil { await broker.activeConnectionCount() == 1 })

        await broker.stop()

        #expect(await broker.activeConnectionCount() == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath) == false)
    }

    @Test("wake handles are claimed once and an expired handle does not consume the persistent listener")
    func wakeClaimAndExpiry() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let clock = DispatchTime.now().uptimeNanoseconds
        let liveHandle = UUID()
        let expiredHandle = UUID()
        try await fixture.registry.registerWake(handle: liveHandle, deadline: clock + 2_000_000_000)
        try await fixture.registry.registerWake(handle: expiredHandle, deadline: clock + 20_000_000)
        let broker = fixture.makeBroker { _, _ in "value" }
        try await broker.start()
        defer { Task { await broker.stop() } }

        let liveResponse = try await request(
            at: fixture.socketPath,
            message: makeWireRequest(kind: .password, wakeHandle: liveHandle)
        )
        guard case .credential = liveResponse else { Issue.record("Live wake handle was rejected"); return }

        try await Task.sleep(for: .milliseconds(30))
        let expiredResponse = try await request(
            at: fixture.socketPath,
            message: makeWireRequest(kind: .password, wakeHandle: expiredHandle)
        )
        guard case .failure(_, let failure) = expiredResponse else {
            Issue.record("Expired wake handle should fail")
            return
        }
        #expect(failure == .unauthorized || failure == .expired)

        let laterResponse = try await request(at: fixture.socketPath, message: makeWireRequest(kind: .password))
        guard case .credential = laterResponse else { Issue.record("Listener stopped after handle expiry"); return }
    }

    @Test("peer close cancels handling without SIGPIPE and later requests still work")
    func peerCloseDoesNotRaiseSIGPIPE() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let cancelledCalls = OSAllocatedUnfairLock(initialState: 0)
        let broker = fixture.makeBroker { _, _ in
            do {
                try await Task.sleep(for: .milliseconds(30))
            } catch {
                cancelledCalls.withLock { $0 += 1 }
                throw error
            }
            return "secret"
        }
        try await broker.start()
        defer { Task { await broker.stop() } }

        let fd = try Self.connect(to: fixture.socketPath)
        try AutoFillWire.writeMessage(makeWireRequest(kind: .password), toFileDescriptor: fd)
        close(fd)
        try await Task.sleep(for: .milliseconds(80))
        #expect(cancelledCalls.withLock { $0 } == 1)

        let response = try await request(at: fixture.socketPath, message: makeWireRequest(kind: .password))
        guard case .credential = response else { Issue.record("Broker did not survive peer close"); return }
    }

    @Test("disconnected candidate requests release their verified connection")
    func disconnectedCandidateReleasesVerifiedConnection() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let handler = CandidateDisconnectHandler()
        let broker = fixture.makeBroker(
            handler: { _, _ in "must-not-resolve" },
            candidateHandler: { _ in await handler.resolve() }
        )
        try await broker.start()

        let fd = try Self.connect(to: fixture.socketPath)
        let query = AutoFillCandidateQuery.global(
            requestID: UUID(),
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        )
        try AutoFillWire.writeMessage(AutoFillBrokerRequest.listCandidates(query), toFileDescriptor: fd)
        await handler.waitUntilStarted()
        close(fd)
        await handler.waitUntilFinished()
        await broker.stop()

        #expect(await fixture.registry.counts().connections == 0)
    }

}

extension AutoFillBrokerTests {
    @Test("candidate requests authenticate and avoid the secret request registry")
    func candidateRequestAvoidsSecretResolution() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let requestID = UUID()
        let query = AutoFillCandidateQuery.global(
            requestID: requestID,
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        )
        let expected = [AutoFillCandidate(
            descriptorID: UUID(),
            title: "Example",
            username: "person@example.com",
            kind: .password,
            matchTier: 0
        )]
        let peerVerificationCalls = OSAllocatedUnfairLock(initialState: 0)
        let secretHandlerCalls = OSAllocatedUnfairLock(initialState: 0)
        let candidateHandlerCalls = OSAllocatedUnfairLock(initialState: 0)
        let broker = fixture.makeBroker(
            verifier: { fd in
                peerVerificationCalls.withLock { $0 += 1 }
                return VerifiedAutoFillPeer(
                    fileDescriptor: fd,
                    identifier: AutoFillConstants.extensionBundleIdentifier,
                    teamID: "H23TXL6LPT"
                )
            },
            handler: { _, _ in
                secretHandlerCalls.withLock { $0 += 1 }
                return "must-not-resolve"
            },
            candidateHandler: { received in
                candidateHandlerCalls.withLock { $0 += 1 }
                #expect(received == query)
                return expected
            }
        )
        try await broker.start()
        defer { Task { await broker.stop() } }

        let response = try await request(at: fixture.socketPath, message: .listCandidates(query))

        #expect(response == .candidates(requestID: requestID, candidates: expected))
        #expect(peerVerificationCalls.withLock { $0 } == 1)
        #expect(candidateHandlerCalls.withLock { $0 } == 1)
        #expect(secretHandlerCalls.withLock { $0 } == 0)
        #expect(await fixture.registry.counts().pendingRequests == 0)
    }

    @Test("cold host candidate listing reconnects with its registered wake handle")
    @MainActor
    func coldHostCandidateListingReconnectsWithWakeHandle() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let expected = [AutoFillCandidate(
            descriptorID: UUID(),
            title: "Example",
            username: "person@example.com",
            kind: .password,
            matchTier: 0
        )]
        let receivedQueries = OSAllocatedUnfairLock(initialState: [AutoFillCandidateQuery]())
        let broker = fixture.makeBroker(
            handler: { _, _ in "must-not-resolve" },
            candidateHandler: { query in
                receivedQueries.withLock { $0.append(query) }
                return expected
            }
        )
        let opener = ColdStartAutoFillHostOpener(
            broker: broker,
            registry: fixture.registry,
            launchGate: fixture.launchGate
        )
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        let query = AutoFillCandidateQuery.global(
            requestID: UUID(),
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: deadline
        )
        let client = AutoFillBrokerClient(
            socketPath: fixture.socketPath,
            hostOpener: opener,
            verifier: { fd in
                VerifiedAutoFillPeer(
                    fileDescriptor: fd,
                    identifier: AutoFillConstants.hostBundleIdentifier,
                    teamID: "H23TXL6LPT"
                )
            },
            retryDelay: .milliseconds(1)
        )

        let candidates = try await client.listCandidates(query, deadline: deadline)
        await broker.stop()

        #expect(candidates == expected)
        let handle = try #require(opener.openedHandles.first)
        #expect(opener.openedHandles.count == 1)
        #expect(receivedQueries.withLock { $0 } == [.global(
            requestID: query.requestID,
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: deadline,
            wakeHandle: handle
        )])
    }

    @Test("extreme candidate deadlines fail before dispatch")
    func extremeCandidateDeadlineFailsBeforeDispatch() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let requestID = UUID()
        let handlerCalls = OSAllocatedUnfairLock(initialState: 0)
        let broker = fixture.makeBroker(
            handler: { _, _ in "must-not-resolve" },
            candidateHandler: { _ in
                handlerCalls.withLock { $0 += 1 }
                return []
            }
        )
        try await broker.start()
        defer { Task { await broker.stop() } }

        let response = try await request(
            at: fixture.socketPath,
            message: .listCandidates(.global(
                requestID: requestID,
                search: "example",
                kind: .password,
                deadlineUptimeNanoseconds: .max
            ))
        )

        #expect(response == .failure(requestID: requestID, failure: .invalidRequest))
        #expect(handlerCalls.withLock { $0 } == 0)
    }

    @Test("overlong direct resolution leaves cold wake admission usable")
    func overlongDirectResolutionPreservesWakeAndBootstrapGate() async throws {
        let clock = BrokerTestClock(now: 100)
        let scheduler = BrokerTestTimeoutScheduler()
        let registry = AutoFillRequestRegistry(now: clock.read, scheduleTimeout: scheduler.schedule)
        let fixture = try BrokerFixture(registry: registry)
        defer { fixture.cleanup() }
        let deadline: UInt64 = 200
        let handle = UUID()
        _ = fixture.launchGate.recordWake(handle: handle, deadline: deadline)
        try await registry.registerWake(handle: handle, deadline: deadline)
        let handlerCalls = OSAllocatedUnfairLock(initialState: 0)
        let broker = fixture.makeBroker { _, _ in
            handlerCalls.withLock { $0 += 1 }
            return "value"
        }
        try await broker.start()
        defer { Task { await broker.stop() } }

        let requestID = UUID()
        let rejected = try await request(
            at: fixture.socketPath,
            message: AutoFillBrokerRequest(
                requestID: requestID,
                descriptorID: UUID(),
                valueKind: .password,
                deadlineUptimeNanoseconds: .max,
                wakeHandle: handle
            )
        )

        #expect(rejected == .failure(requestID: requestID, failure: .invalidRequest))
        #expect(handlerCalls.withLock { $0 } == 0)
        #expect(await registry.counts().wakeHandles == 1)
        #expect(await registry.counts().connections == 0)
        #expect(fixture.launchGate.requiresInitialClaim(at: clock.read()))

        let connectionID = UUID()
        try await registry.bindVerifiedConnection(
            connectionID,
            peer: VerifiedAutoFillPeer(
                fileDescriptor: 9,
                identifier: AutoFillConstants.extensionBundleIdentifier,
                teamID: "H23TXL6LPT"
            ),
            wakeHandle: handle,
            requestDeadline: deadline
        )
        fixture.launchGate.completeInitialClaim(handle: handle, deadline: deadline)
        #expect(await registry.claimedWakeDeadline(connectionID: connectionID) == deadline)
        #expect(fixture.launchGate.requiresInitialClaim(at: clock.read()) == false)
    }

}

extension AutoFillBrokerTests {
    @Test("resolution failures expose only a fixed non-secret failure code")
    func failurePayloadDoesNotContainSecret() async throws {
        struct SecretBearingError: Error {
            let text: String
        }

        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let broker = fixture.makeBroker { _, _ in
            throw SecretBearingError(text: "must-never-cross-the-wire")
        }
        try await broker.start()
        defer { Task { await broker.stop() } }

        let response = try await request(at: fixture.socketPath, message: makeWireRequest(kind: .password))

        guard case .failure(_, let failure) = response else {
            Issue.record("Expected a fixed broker failure")
            return
        }
        #expect(failure == .resolutionFailed)
        #expect(String(data: try AutoFillWire.encodeMessage(response), encoding: .utf8)?.contains("must-never-cross-the-wire") == false)
    }

    @Test("partial credential frame holds its accepted owner while a later accepted request survives cleanup")
    func partialFrameDoesNotCloseLaterAcceptedConnection() async throws {
        let fixture = try BrokerFixture()
        let partialGate = OfflineTestGate()
        let secondHandlerGate = OfflineTestGate()
        let handlerCalls = OSAllocatedUnfairLock(initialState: 0)
        let broker = fixture.makeBroker(
            verifier: { fd in
                var sendBuffer: Int32 = 1024
                guard setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw AutoFillPeerVerificationError.invalidPeer
                }
                return VerifiedAutoFillPeer(
                    fileDescriptor: fd, identifier: AutoFillConstants.extensionBundleIdentifier, teamID: "H23TXL6LPT"
                )
            },
            partialDeliveryGate: { try? await partialGate.wait() },
            handler: { _, _ in
                let call = handlerCalls.withLock { count in count += 1; return count }
                if call == 1 { return String(repeating: "x", count: 60_000) }
                try await secondHandlerGate.wait()
                return "second-accepted-connection"
            }
        )
        try await broker.start()
        let socketPath = fixture.socketPath
        let firstFD = try Self.connect(to: socketPath)
        var secondLaunched = false
        let secondFinished = OfflineTestGate()
        do {
            try AutoFillWire.writeMessage(makeWireRequest(kind: .password), toFileDescriptor: firstFD)
            try await partialGate.waitUntilEntered()
            #expect(await broker.activeConnectionCount() == 1)

            let secondRequest = makeWireRequest(kind: .password)
            let secondResult = OSAllocatedUnfairLock<AutoFillBrokerResponse?>(initialState: nil)
            secondLaunched = true
            Self.blockingSocketQueue.async {
                let response = try? Self.requestBlocking(at: socketPath, message: secondRequest)
                secondResult.withLock { $0 = response }
                Task { await secondFinished.open() }
            }
            try await secondHandlerGate.waitUntilEntered()
            #expect(await broker.activeConnectionCount() == 2)

            await partialGate.open()
            #expect(await waitUntil { await broker.activeConnectionCount() == 1 })
            await secondHandlerGate.open()
            try await secondFinished.wait()
            guard case .credential(_, let secondValue) = secondResult.withLock({ $0 }) else {
                Issue.record("Later accepted request did not receive a credential")
                close(firstFD)
                await broker.stop()
                fixture.cleanup()
                return
            }
            #expect(secondValue == "second-accepted-connection")

            let firstBytes = try await BrokerTestSocketIO.readUntilEOF(from: firstFD)
            guard firstBytes.count > MemoryLayout<UInt32>.size else {
                Issue.record("Partial credential stream had no credential bytes")
                close(firstFD)
                await broker.stop()
                fixture.cleanup()
                return
            }
            let expectedLength = firstBytes.prefix(MemoryLayout<UInt32>.size).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let body = firstBytes.dropFirst(MemoryLayout<UInt32>.size)
            #expect(UInt32(body.count) < expectedLength)
            #expect(body.contains(0) == false)
            close(firstFD)
            await broker.stop()
            fixture.cleanup()
        } catch {
            await partialGate.open()
            await secondHandlerGate.open()
            if secondLaunched { try? await secondFinished.wait() }
            close(firstFD)
            await broker.stop()
            fixture.cleanup()
            throw error
        }
    }

    private func makeWireRequest(
        kind: AutoFillValueKind,
        wakeHandle: UUID? = nil,
        deadline: UInt64? = nil
    ) -> AutoFillBrokerRequest {
        AutoFillBrokerRequest(
            requestID: UUID(),
            descriptorID: UUID(),
            valueKind: kind,
            deadlineUptimeNanoseconds: deadline ?? DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            wakeHandle: wakeHandle
        )
    }

    private func responseCategory(_ response: AutoFillBrokerResponse) -> String {
        switch response {
        case .credential:
            "credential"
        case .candidates:
            "candidates"
        case .failure(_, let failure):
            "failure.\(failure.rawValue)"
        }
    }

    private func request(at path: String, message: AutoFillBrokerRequest) async throws -> AutoFillBrokerResponse {
        try await Self.requestAsync(at: path, message: message)
    }

    private static func requestAsync(at path: String, message: AutoFillBrokerRequest) async throws -> AutoFillBrokerResponse {
        try await withCheckedThrowingContinuation { continuation in
            Self.blockingSocketQueue.async {
                do {
                    continuation.resume(returning: try Self.requestBlocking(at: path, message: message))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func request(at path: String, kind: AutoFillValueKind) async throws -> AutoFillBrokerResponse {
        try await withCheckedThrowingContinuation { continuation in
            Self.blockingSocketQueue.async {
                do {
                    let message = AutoFillBrokerRequest(
                        requestID: UUID(),
                        descriptorID: UUID(),
                        valueKind: kind,
                        deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000
                    )
                    continuation.resume(returning: try Self.requestBlocking(at: path, message: message))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private static let blockingSocketQueue = DispatchQueue(
        label: "codes.petr.quick-access-for-pass.tests.autofill-broker-socket",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static func requestBlocking(
        at path: String,
        message: AutoFillBrokerRequest
    ) throws -> AutoFillBrokerResponse {
        let fd = try Self.connect(to: path)
        defer { close(fd) }
        try AutoFillWire.writeMessage(message, toFileDescriptor: fd)
        return try AutoFillWire.readMessage(AutoFillBrokerResponse.self, fromFileDescriptor: fd)
    }


    private static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ECONNREFUSED) }
        var address = SSHAgentConstants.makeUnixAddr(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
        return fd
    }

    private func permissions(at path: String) throws -> mode_t {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        return metadata.st_mode & mode_t(0o777)
    }

    private func waitUntil(
        timeout: TimeInterval = 0.5,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

extension AutoFillBrokerTests {
    @Test("a cold no-handle credential request is rejected before secret resolution")
    func coldResolutionRequiresClaim() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        _ = fixture.launchGate.recordWake(handle: UUID(), deadline: deadline)
        let candidateCalls = OSAllocatedUnfairLock(initialState: 0)
        let secretCalls = OSAllocatedUnfairLock(initialState: 0)
        let broker = fixture.makeBroker(
            handler: { _, _ in
                secretCalls.withLock { $0 += 1 }
                return "must-not-resolve"
            },
            candidateHandler: { _ in
                candidateCalls.withLock { $0 += 1 }
                return []
            }
        )
        try await broker.start()
        defer { Task { await broker.stop() } }

        let response = try await request(
            at: fixture.socketPath,
            message: makeWireRequest(kind: .password, deadline: deadline)
        )

        guard case .failure(_, let failure) = response else {
            Issue.record("Cold no-handle resolution should be unauthorized")
            return
        }
        #expect(failure == .unauthorized)
        #expect(secretCalls.withLock { $0 } == 0)
        #expect(candidateCalls.withLock { $0 } == 0)
        #expect(fixture.launchGate.requiresInitialClaim(at: DispatchTime.now().uptimeNanoseconds))
    }

    @Test("a cold candidate claim enables a later warm resolution")
    func candidateClaimWarmsBroker() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        let handle = UUID()
        _ = fixture.launchGate.recordWake(handle: handle, deadline: deadline)
        try await fixture.registry.registerWake(handle: handle, deadline: deadline)
        let candidateCalls = OSAllocatedUnfairLock(initialState: 0)
        let secretCalls = OSAllocatedUnfairLock(initialState: 0)
        let expected = [AutoFillCandidate(
            descriptorID: UUID(),
            title: "Example",
            username: "person@example.com",
            kind: .password,
            matchTier: 0
        )]
        let broker = fixture.makeBroker(
            handler: { _, _ in
                secretCalls.withLock { $0 += 1 }
                return "resolved"
            },
            candidateHandler: { _ in
                candidateCalls.withLock { $0 += 1 }
                return expected
            }
        )
        try await broker.start()
        defer { Task { await broker.stop() } }

        let candidateResponse = try await request(
            at: fixture.socketPath,
            message: .listCandidates(.global(
                requestID: UUID(),
                search: "example",
                kind: .password,
                deadlineUptimeNanoseconds: deadline,
                wakeHandle: handle
            ))
        )
        guard case .candidates(_, let candidates) = candidateResponse else {
            Issue.record("Cold candidate claim should succeed")
            return
        }
        #expect(candidates == expected)
        #expect(fixture.launchGate.requiresInitialClaim(at: DispatchTime.now().uptimeNanoseconds) == false)

        let credentialResponse = try await request(
            at: fixture.socketPath,
            message: makeWireRequest(kind: .password, deadline: deadline)
        )
        guard case .credential(_, let value) = credentialResponse else {
            Issue.record("Warm credential request should succeed")
            return
        }
        #expect(value == "resolved")
        #expect(candidateCalls.withLock { $0 } == 1)
        #expect(secretCalls.withLock { $0 } == 1)
    }

    @Test("deadline-mismatched wake claims leave the handle available")
    func deadlineMismatchedWakeClaimPreservesHandle() async throws {
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let clock = DispatchTime.now().uptimeNanoseconds
        let handle = UUID()
        let wakeDeadline = clock + 2_000_000_000
        try await fixture.registry.registerWake(handle: handle, deadline: wakeDeadline)
        let handlerCalls = OSAllocatedUnfairLock(initialState: 0)
        let broker = fixture.makeBroker { _, _ in
            handlerCalls.withLock { $0 += 1 }
            return "value"
        }
        try await broker.start()
        defer { Task { await broker.stop() } }

        let rejected = try await request(
            at: fixture.socketPath,
            message: makeWireRequest(
                kind: .password,
                wakeHandle: handle,
                deadline: wakeDeadline + 1
            )
        )
        guard case .failure(_, let failure) = rejected else {
            Issue.record("Deadline-mismatched wake claim should fail")
            return
        }
        #expect(failure == .unauthorized)
        #expect(handlerCalls.withLock { $0 } == 0)

        let accepted = try await request(
            at: fixture.socketPath,
            message: makeWireRequest(
                kind: .password,
                wakeHandle: handle,
                deadline: clock + 1_000_000_000
            )
        )
        guard case .credential = accepted else {
            Issue.record("Handle should remain available after rejected claim")
            return
        }
        #expect(handlerCalls.withLock { $0 } == 1)
    }
}
private actor CapacityBlockingCandidateHandler {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func resolve(_: AutoFillCandidateQuery) async -> [AutoFillCandidate] {
        started = true
        await withCheckedContinuation { releaseContinuation = $0 }
        return []
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CandidateDisconnectHandler {
    private var started = false
    private var finished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false

    func resolve() async -> [AutoFillCandidate] {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancellationRequested {
                    continuation.resume()
                } else {
                    cancellationContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.finishCancellation() }
        }

        finished = true
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
        return []
    }

    func waitUntilStarted() async {
        guard started == false else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilFinished() async {
        guard finished == false else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    private func finishCancellation() {
        cancellationRequested = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}
@MainActor
private final class ColdStartAutoFillHostOpener: AutoFillHostOpening {
    private let broker: AutoFillBroker
    private let registry: AutoFillRequestRegistry
    private let launchGate: AutoFillLaunchGate
    private(set) var openedHandles: [UUID] = []

    init(
        broker: AutoFillBroker,
        registry: AutoFillRequestRegistry,
        launchGate: AutoFillLaunchGate
    ) {
        self.broker = broker
        self.registry = registry
        self.launchGate = launchGate
    }

    func open(handle: UUID) async throws -> Bool {
        openedHandles.append(handle)
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        _ = launchGate.recordWake(handle: handle, deadline: deadline)
        try await registry.registerWake(handle: handle, deadline: deadline)
        try await broker.start()
        launchGate.markListenerReady()
        return true
    }
}
private final class BrokerTestClock: Sendable {
    private let value: Mutex<UInt64>

    init(now: UInt64) {
        value = Mutex(now)
    }

    func read() -> UInt64 {
        value.withLock { $0 }
    }
}
private final class BrokerTestTimeoutScheduler: Sendable {
    func schedule(
        after _: Duration,
        operation _: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {}
    }
}
