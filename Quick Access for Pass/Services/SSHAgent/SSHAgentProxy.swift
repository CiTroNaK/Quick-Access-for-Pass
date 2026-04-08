import Foundation
import os

nonisolated enum SSHAuthorizationResult: Sendable {
    case allow
    case deny
}

typealias SSHAuthorizationHandler = @Sendable (Data, VerifiedConnection) async -> SSHAuthorizationResult

actor SSHAgentProxy {
    private struct AcceptContext {
        let verifier: @Sendable (Int32) -> VerifiedConnection
        let upstreamPath: String
        let authorizationHandler: SSHAuthorizationHandler
        let failureSignal: @Sendable (SSHClientLoopFailure) -> Void
        let activeClientFDs: OSAllocatedUnfairLock<Set<Int32>>
    }

    private let listenPath: String
    private let upstreamPath: String
    private let authorizationHandler: SSHAuthorizationHandler
    private let failureSignal: @Sendable (SSHClientLoopFailure) -> Void
    private let verifier: @Sendable (Int32) -> VerifiedConnection
    private nonisolated let activeClientFDs = OSAllocatedUnfairLock(initialState: Set<Int32>())
    private var serverFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(
        listenPath: String,
        upstreamPath: String,
        authorizationHandler: @escaping SSHAuthorizationHandler,
        failureSignal: @escaping @Sendable (SSHClientLoopFailure) -> Void,
        verifier: @escaping @Sendable (Int32) -> VerifiedConnection = PeerVerifier.verify
    ) {
        self.listenPath = listenPath
        self.upstreamPath = upstreamPath
        self.authorizationHandler = authorizationHandler
        self.failureSignal = failureSignal
        self.verifier = verifier
    }

    func start() throws {
        guard listenPath.utf8.count < SSHAgentConstants.maxSocketPathLength else {
            throw SSHAgentError.socketPathTooLong(listenPath)
        }
        guard upstreamPath.utf8.count < SSHAgentConstants.maxSocketPathLength else {
            throw SSHAgentError.socketPathTooLong(upstreamPath)
        }

        let fd = try createListeningSocket()
        serverFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        let capturedVerifier = verifier
        let capturedUpstreamPath = upstreamPath
        let capturedHandler = authorizationHandler
        let capturedFailureSignal = failureSignal

        let acceptContext = AcceptContext(
            verifier: capturedVerifier,
            upstreamPath: capturedUpstreamPath,
            authorizationHandler: capturedHandler,
            failureSignal: capturedFailureSignal,
            activeClientFDs: activeClientFDs
        )

        source.setEventHandler {
            Self.handleAcceptedClient(serverFD: fd, context: acceptContext)
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
        guard fd >= 0 else {
            throw SSHAgentError.socketBindFailed
        }

        var addr = SSHAgentConstants.makeUnixAddr(path: listenPath)
        let previousUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousUmask)

        guard bindResult == 0 else {
            close(fd)
            throw SSHAgentError.socketBindFailed
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(listenPath)
            throw SSHAgentError.socketBindFailed
        }
        guard chmod(listenPath, 0o600) == 0 else {
            close(fd)
            unlink(listenPath)
            throw SSHAgentError.socketBindFailed
        }
        return fd
    }

    private static func handleAcceptedClient(
        serverFD: Int32,
        context: AcceptContext
    ) {
        let clientFd = accept(serverFD, nil, nil)
        guard clientFd >= 0 else { return }

        _ = context.activeClientFDs.withLock { $0.insert(clientFd) }
        let connection = context.verifier(clientFd)
        guard connection.pid != 0 else {
            AppLogger.sshProxy.warning(
                "Rejecting connection: failed to extract peer identity from fd \(clientFd, privacy: .public)"
            )
            _ = context.activeClientFDs.withLock { $0.remove(clientFd) }
            close(clientFd)
            return
        }

        Task.detached { [activeClientFDs = context.activeClientFDs] in
            await Self.handleClient(
                connection: connection,
                upstreamPath: context.upstreamPath,
                authorizationHandler: context.authorizationHandler,
                failureSignal: context.failureSignal
            )
            _ = activeClientFDs.withLock { $0.remove(connection.fd) }
        }
    }

    private static func handleClient(
        connection: VerifiedConnection,
        upstreamPath: String,
        authorizationHandler: @escaping SSHAuthorizationHandler,
        failureSignal: @escaping @Sendable (SSHClientLoopFailure) -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                Self.runClientLoop(
                    connection: connection,
                    upstreamPath: upstreamPath,
                    authorizationHandler: authorizationHandler,
                    failureSignal: failureSignal,
                    completion: { continuation.resume() }
                )
            }
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func runClientLoop(
        connection: VerifiedConnection,
        upstreamPath: String,
        authorizationHandler: @escaping SSHAuthorizationHandler,
        failureSignal: @escaping @Sendable (SSHClientLoopFailure) -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        defer {
            close(connection.fd)
            completion()
        }

        let pid = connection.pid
        let clientHandle = FileHandle(fileDescriptor: connection.fd, closeOnDealloc: false)

        let upstreamFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard upstreamFd >= 0 else { return }
        defer { close(upstreamFd) }

        var upstreamAddr = SSHAgentConstants.makeUnixAddr(path: upstreamPath)
        let connectResult = withUnsafePointer(to: &upstreamAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(upstreamFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let err = errno
            AppLogger.sshProxy.error("upstream connect failed pid=\(pid, privacy: .public) errno=\(err, privacy: .public)")
            failureSignal(.upstreamConnectFailed(errno: err))
            return
        }

        let upstreamHandle = FileHandle(fileDescriptor: upstreamFd, closeOnDealloc: false)

        while true {
            let message: SSHAgentMessage
            do {
                message = try SSHAgentMessage.read(from: clientHandle)
            } catch {
                AppLogger.sshProxy.debug("client closed or read failed pid=\(pid, privacy: .public)")
                break
            }

            if message.type == .signRequest {
                let keyBlob = message.keyBlob ?? Data()
                let semaphore = DispatchSemaphore(value: 0)
                let box = FinalizableBox<SSHAuthorizationResult>(initial: .deny)
                let handler = authorizationHandler
                Task.detached { @Sendable in
                    let outcome = await handler(keyBlob, connection)
                    box.setIfNotFinalized(outcome)
                    semaphore.signal()
                }

                let result: SSHAuthorizationResult
                if semaphore.wait(timeout: .now() + 60) == .timedOut {
                    result = box.finalize(.deny)
                } else {
                    result = box.value
                }

                switch result {
                case .deny:
                    try? clientHandle.writeAll(SSHAgentMessage.failureResponse())
                    continue
                case .allow:
                    break
                }
            }

            do {
                try upstreamHandle.writeAll(message.serialize())
            } catch {
                AppLogger.sshProxy.error("upstream write failed pid=\(pid, privacy: .public)")
                failureSignal(.upstreamWriteFailed)
                break
            }

            let response: SSHAgentMessage
            do {
                response = try SSHAgentMessage.read(from: upstreamHandle)
            } catch {
                AppLogger.sshProxy.error("upstream response read failed pid=\(pid, privacy: .public)")
                failureSignal(.upstreamResponseReadFailed)
                try? clientHandle.writeAll(SSHAgentMessage.failureResponse())
                break
            }

            if response.type == .identitiesAnswer, let identities = try? response.parseIdentities() {
                for identity in identities {
                    SSHKeyNameCache.shared.store(keyBlob: identity.keyBlob, comment: identity.comment)
                }
            }

            do {
                try clientHandle.writeAll(response.serialize())
            } catch {
                break
            }
        }
    }
}
