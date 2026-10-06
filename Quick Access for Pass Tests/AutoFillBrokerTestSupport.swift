import Darwin
import Foundation
import os
@testable import Quick_Access_for_Pass

final class BrokerFixture {
    let rootURL: URL
    let directoryPath: String
    let socketPath: String
    let registry: AutoFillRequestRegistry
    let launchGate = AutoFillLaunchGate()

    init(registry: AutoFillRequestRegistry = AutoFillRequestRegistry()) throws {
        self.registry = registry
        rootURL = URL(fileURLWithPath: "/tmp/qafb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        directoryPath = rootURL.appendingPathComponent("broker", isDirectory: true).path
        socketPath = rootURL.appendingPathComponent("broker/autofill.sock").path
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func makeBroker(
        maximumConnections: Int = 8,
        idleTimeout: TimeInterval = 0.2,
        verifier: @escaping @Sendable (Int32) throws -> VerifiedAutoFillPeer = { fd in
            VerifiedAutoFillPeer(fileDescriptor: fd, identifier: AutoFillConstants.extensionBundleIdentifier, teamID: "H23TXL6LPT")
        },
        releaseGuard: SecretReleaseGuard? = nil,
        completionGate: (@Sendable () async -> Void)? = nil,
        partialDeliveryGate: (@Sendable () async -> Void)? = nil,
        handler: @escaping @Sendable (AutoFillRegisteredRequest, AutoFillBrokerStateTransition) async throws -> String,
        candidateHandler: @escaping AutoFillBrokerCandidateHandler = { _ in [] }
    ) -> AutoFillBroker {
        let releaseGuard = releaseGuard ?? SecretReleaseGuard()
        return AutoFillBroker(
            listenPath: socketPath, registry: registry, launchGate: launchGate,
            maximumConnections: maximumConnections, idleTimeout: idleTimeout, verifier: verifier,
            requestHandler: { request, transition, _ in
                let descriptor = AutoFillCredentialDescriptor(
                    id: request.descriptorID, vaultID: "test-vault", itemID: "test-item", shareID: "test-share",
                    title: "Test", username: "test@example.test", serviceIdentifier: "example.test", hasTOTP: true
                )
                return AutoFillCredentialDelivery(
                    value: try await handler(request, transition),
                    release: await AutoFillCredentialRelease(
                        request: request, descriptor: descriptor, releaseToken: releaseGuard.capture(),
                        descriptorStore: AutoFillBrokerTestDescriptorStore(descriptor: descriptor),
                        secretReleaseGuard: releaseGuard, isAppLocked: { false },
                        now: { DispatchTime.now().uptimeNanoseconds }
                    )
                )
            },
            candidateHandler: candidateHandler, completionGate: completionGate, partialDeliveryGate: partialDeliveryGate
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: rootURL) }
}

private actor AutoFillBrokerTestDescriptorStore: AutoFillDescriptorStoring {
    let storedDescriptor: AutoFillCredentialDescriptor
    init(descriptor: AutoFillCredentialDescriptor) { storedDescriptor = descriptor }
    func descriptor(id: UUID) -> AutoFillCredentialDescriptor? { id == storedDescriptor.id ? storedDescriptor : nil }
}

nonisolated func makeAutoFillBrokerTestDescriptorStore(
    descriptor: AutoFillCredentialDescriptor
) -> any AutoFillDescriptorStoring {
    AutoFillBrokerTestDescriptorStore(descriptor: descriptor)
}

/// Bounded fixed metadata tracing for causal broker-test diagnostics.
enum BrokerTestSocketIO {
    private static let queue = DispatchQueue(
        label: "codes.petr.quick-access-for-pass.tests.autofill-broker-trace",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func requestTraced(
        at path: String,
        message: AutoFillBrokerRequest,
        trace: BrokerTestTrace
    ) async throws -> AutoFillBrokerResponse {
        try await requestTraced(at: path, trace: trace) { message }
    }

    /// Builds deadline-bound requests on the blocking I/O worker so executor
    /// queueing cannot make a one-second causal fixture stale before connect.
    static func requestTraced(
        at path: String,
        trace: BrokerTestTrace,
        makeMessage: @escaping @Sendable () -> AutoFillBrokerRequest
    ) async throws -> AutoFillBrokerResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let message = makeMessage()
                    trace.record(message.deadlineUptimeNanoseconds > DispatchTime.now().uptimeNanoseconds ? .deadlineFuture : .deadlineExpired)
                    trace.record(.queued)
                    let fd = try connect(to: path)
                    trace.record(.connected)
                    defer { close(fd) }
                    try AutoFillWire.writeMessage(message, toFileDescriptor: fd)
                    trace.record(.framed)
                    let response = try AutoFillWire.readMessage(AutoFillBrokerResponse.self, fromFileDescriptor: fd)
                    switch response {
                    case .credential: trace.record(.credentialResponse)
                    case .failure, .candidates: trace.record(.failureResponse)
                    }
                    continuation.resume(returning: response)
                } catch {
                    trace.record(.transportFailure)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func readUntilEOF(from fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let flags = fcntl(fd, F_GETFL, 0)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL))
                    return
                }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let result = Darwin.read(fd, &buffer, buffer.count)
                    if result > 0 { bytes.append(buffer, count: result); continue }
                    if result == 0 { continuation.resume(returning: bytes); return }
                    guard errno == EAGAIN || errno == EWOULDBLOCK else {
                        continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                        return
                    }
                    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&ready, 1, 1_000) > 0 else {
                        continuation.resume(throwing: POSIXError(.ETIMEDOUT))
                        return
                    }
                }
            }
        }
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
}

final class BrokerTestTrace: Sendable {
    enum Event: String, Sendable {
        case workerReady, prepared, queued, connected, framed, handler, handlerReturned, releaseConstructed, completionGate
        case credentialResponse, failureResponse, expiredResponse, transportFailure
        case deadlineFuture, deadlineExpired, handlerDeadlineFuture, handlerDeadlineExpired
    }

    private let events = OSAllocatedUnfairLock<[Event]>(initialState: [])

    func record(_ event: Event) {
        events.withLock {
            guard $0.count < 32 else { return }
            $0.append(event)
        }
    }

    func snapshot() -> [Event] { events.withLock { $0 } }
}

struct BrokerTestPreparedDelivery: Sendable {
    let request: AutoFillBrokerRequest
    let registeredRequest: AutoFillRegisteredRequest
    let delivery: AutoFillCredentialDelivery
}

/// Test-only handoff that lets a dedicated blocking I/O worker announce it is
/// ready before MainActor creates one exact deadline-bound delivery. Its lock
/// protects only state copies; socket I/O and continuation resumption are
/// always outside the lock.
final class BrokerTestDeliveryHandoff: Sendable {
    enum Error: Swift.Error {
        case preparationTimedOut
        case cancelled
    }

    private struct State {
        var workerReady = false
        var cancelled = false
        var readyContinuation: CheckedContinuation<Void, Never>?
        var prepared: BrokerTestPreparedDelivery?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let preparedSignal = DispatchSemaphore(value: 0)

    func waitUntilWorkerReady() async throws {
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLock { state in
                    if state.workerReady || state.cancelled { return true }
                    state.readyContinuation = continuation
                    return false
                }
                if shouldResume { continuation.resume() }
            }
            try Task.checkCancellation()
            guard state.withLock({ $0.cancelled == false }) else { throw Error.cancelled }
        } onCancel: {
            cancel()
        }
    }

    func publish(_ prepared: BrokerTestPreparedDelivery) throws {
        let published = state.withLock { state in
            guard state.cancelled == false, state.prepared == nil else { return false }
            state.prepared = prepared
            return true
        }
        guard published else { throw Error.cancelled }
        preparedSignal.signal()
    }

    func delivery(matching admittedRequest: AutoFillRegisteredRequest) -> AutoFillCredentialDelivery? {
        state.withLock { state in
            guard state.cancelled == false,
                  let prepared = state.prepared,
                  prepared.registeredRequest == admittedRequest
            else { return nil }
            return prepared.delivery
        }
    }

    func waitForPreparedDelivery() throws -> BrokerTestPreparedDelivery {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.workerReady = true
            defer { state.readyContinuation = nil }
            return state.readyContinuation
        }
        continuation?.resume()
        // This bounds fixture setup before the protocol deadline exists; it
        // is deliberately separate from the request's unchanged one-second
        // lifetime, which begins only after MainActor publishes the tuple.
        guard preparedSignal.wait(timeout: .now() + 60) == .success else {
            cancel()
            throw Error.preparationTimedOut
        }
        return try state.withLock { state in
            guard state.cancelled == false, let prepared = state.prepared else { throw Error.cancelled }
            return prepared
        }
    }

    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard state.cancelled == false else { return nil }
            state.cancelled = true
            defer { state.readyContinuation = nil }
            return state.readyContinuation
        }
        continuation?.resume()
        preparedSignal.signal()
    }
}

extension BrokerTestSocketIO {
    static func requestWithPreparedDelivery(
        at path: String,
        handoff: BrokerTestDeliveryHandoff,
        trace: BrokerTestTrace
    ) async throws -> AutoFillBrokerResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    trace.record(.workerReady)
                    let prepared = try handoff.waitForPreparedDelivery()
                    trace.record(.prepared)
                    let fd = try connect(to: path)
                    trace.record(.connected)
                    defer { close(fd) }
                    try AutoFillWire.writeMessage(prepared.request, toFileDescriptor: fd)
                    trace.record(.framed)
                    let response = try AutoFillWire.readMessage(AutoFillBrokerResponse.self, fromFileDescriptor: fd)
                    switch response {
                    case .credential: trace.record(.credentialResponse)
                    case .failure(_, let failure): trace.record(failure == .expired ? .expiredResponse : .failureResponse)
                    case .candidates: trace.record(.failureResponse)
                    }
                    continuation.resume(returning: response)
                } catch {
                    trace.record(.transportFailure)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
