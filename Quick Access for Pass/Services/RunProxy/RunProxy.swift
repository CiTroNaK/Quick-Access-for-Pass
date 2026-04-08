import Foundation
import os

typealias RunAuthorizationHandler = @Sendable (RunProxyRequest, VerifiedConnection) async -> RunProxyResponse

actor RunProxy {
    private let listenPath: String
    private let authorizationHandler: RunAuthorizationHandler
    private let failureSignal: @Sendable (RunClientLoopFailure) -> Void
    private let verifier: @Sendable (Int32) -> VerifiedConnection
    private nonisolated let activeClientFDs = OSAllocatedUnfairLock(initialState: Set<Int32>())
    private var serverFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(
        listenPath: String,
        authorizationHandler: @escaping RunAuthorizationHandler,
        failureSignal: @escaping @Sendable (RunClientLoopFailure) -> Void = { _ in },
        verifier: @escaping @Sendable (Int32) -> VerifiedConnection = PeerVerifier.verify
    ) {
        self.listenPath = listenPath
        self.authorizationHandler = authorizationHandler
        self.failureSignal = failureSignal
        self.verifier = verifier
    }

    func start() throws {
        guard listenPath.utf8.count < SSHAgentConstants.maxSocketPathLength else {
            throw RunProxyError.invalidMessage
        }

        let fd = try createListeningSocket()
        serverFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        let capturedHandler = authorizationHandler
        let capturedFailureSignal = failureSignal
        let capturedVerifier = verifier

        source.setEventHandler { [activeClientFDs] in
            Self.handleAcceptedClient(
                serverFD: fd,
                verifier: capturedVerifier,
                authorizationHandler: capturedHandler,
                failureSignal: capturedFailureSignal,
                activeClientFDs: activeClientFDs
            )
        }
        source.setCancelHandler {}
        source.resume()
        acceptSource = source
    }

    func stop() {
        if let source = acceptSource {
            source.cancel()
            acceptSource = nil
            close(serverFd)
            serverFd = -1
        } else if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }

        activeClientFDs.withLock { fds in
            for fd in fds {
                Darwin.shutdown(fd, SHUT_RDWR)
            }
            fds.removeAll()
        }

        unlink(listenPath)
    }

    private func createListeningSocket() throws -> Int32 {
        let dirPath = (listenPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dirPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        unlink(listenPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RunProxyError.connectionClosed }

        var addr = SSHAgentConstants.makeUnixAddr(path: listenPath)
        let previousUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousUmask)

        guard bindResult == 0 else {
            close(fd)
            throw RunProxyError.connectionClosed
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(listenPath)
            throw RunProxyError.connectionClosed
        }
        guard chmod(listenPath, 0o600) == 0 else {
            close(fd)
            unlink(listenPath)
            throw RunProxyError.connectionClosed
        }
        return fd
    }

    private static func handleAcceptedClient(
        serverFD: Int32,
        verifier: @escaping @Sendable (Int32) -> VerifiedConnection,
        authorizationHandler: @escaping RunAuthorizationHandler,
        failureSignal: @escaping @Sendable (RunClientLoopFailure) -> Void,
        activeClientFDs: OSAllocatedUnfairLock<Set<Int32>>
    ) {
        let clientFd = accept(serverFD, nil, nil)
        guard clientFd >= 0 else { return }

        _ = activeClientFDs.withLock { $0.insert(clientFd) }
        let connection = verifier(clientFd)

        guard connection.pid != 0 else {
            AppLogger.runProxy.warning(
                "Rejecting connection: failed to extract peer identity from fd \(clientFd, privacy: .public)"
            )
            _ = activeClientFDs.withLock { $0.remove(clientFd) }
            close(clientFd)
            return
        }

        if case .unverified = connection.identity {
            AppLogger.runProxy.warning(
                "Rejecting unverified peer pid \(connection.pid, privacy: .public) — only signed apps and qa-run helper are accepted"
            )
            _ = activeClientFDs.withLock { $0.remove(clientFd) }
            close(clientFd)
            return
        }

        Task.detached { [activeClientFDs] in
            await Self.handleClient(
                connection: connection,
                authorizationHandler: authorizationHandler,
                failureSignal: failureSignal
            )
            _ = activeClientFDs.withLock { $0.remove(connection.fd) }
        }
    }

    private static func handleClient(
        connection: VerifiedConnection,
        authorizationHandler: @escaping RunAuthorizationHandler,
        failureSignal: @escaping @Sendable (RunClientLoopFailure) -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                defer {
                    close(connection.fd)
                    continuation.resume()
                }

                let handle = FileHandle(fileDescriptor: connection.fd, closeOnDealloc: false)

                let request: RunProxyRequest
                do {
                    request = try RunProxyWire.readMessage(RunProxyRequest.self, from: handle)
                } catch {
                    AppLogger.runProxy.error("run client request read failed")
                    failureSignal(.clientRequestReadFailed)
                    return
                }

                if handlePingProbe(request: request, handle: handle, failureSignal: failureSignal) {
                    return
                }

                let verifiedRequest = RunProxyRequest(
                    profile: request.profile,
                    command: request.command,
                    pid: connection.pid
                )

                let semaphore = DispatchSemaphore(value: 0)
                let box = FinalizableBox<RunProxyResponse>(initial: RunProxyResponse(decision: .deny, env: nil))
                let handler = authorizationHandler
                Task.detached { @Sendable in
                    let outcome = await handler(verifiedRequest, connection)
                    box.setIfNotFinalized(outcome)
                    semaphore.signal()
                }

                let response: RunProxyResponse
                if semaphore.wait(timeout: .now() + 60) == .timedOut {
                    AppLogger.runProxy.error("run auth handler timed out")
                    failureSignal(.authHandlerTimedOut)
                    response = box.finalize(RunProxyResponse(decision: .deny, env: nil))
                } else {
                    response = box.value
                }

                do {
                    try RunProxyWire.writeMessage(response, to: handle)
                } catch {
                    AppLogger.runProxy.error("run client response write failed")
                    failureSignal(.clientResponseWriteFailed)
                    return
                }
            }
        }
    }

    private static func handlePingProbe(
        request: RunProxyRequest,
        handle: FileHandle,
        failureSignal: @escaping @Sendable (RunClientLoopFailure) -> Void
    ) -> Bool {
        guard request.profile == RunProxyProbeConstants.reservedPingSlug else { return false }
        AppLogger.runProxy.debug("run probe ping received")
        do {
            try RunProxyWire.writeMessage(
                RunProxyResponse(decision: .allow, env: nil),
                to: handle
            )
        } catch {
            AppLogger.runProxy.error("run probe ping write failed")
            failureSignal(.clientResponseWriteFailed)
        }
        return true
    }
}
