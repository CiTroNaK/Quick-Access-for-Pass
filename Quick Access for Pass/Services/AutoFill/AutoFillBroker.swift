import Darwin
import Foundation
import os

typealias AutoFillBrokerStateTransition = @Sendable (AutoFillRequestState) async throws -> Void
typealias AutoFillBrokerRequestHandler = @Sendable (
    AutoFillRegisteredRequest,
    AutoFillBrokerStateTransition,
    AutoFillAppAssociationIntent?
) async throws -> String
typealias AutoFillBrokerCandidateHandler = @Sendable (AutoFillCandidateQuery) async throws -> [AutoFillCandidate]

nonisolated enum AutoFillBrokerError: Error, Equatable, Sendable {
    case alreadyStarted
    case invalidSocketPath
    case socketSetupFailed
    case disconnected
    case requestRejected
}

/// Persistent host-only listener for the dedicated AutoFill protocol.
/// Peer verification is completed before the first request byte is read.
actor AutoFillBroker {
    private let listenPath: String
    private let registry: AutoFillRequestRegistry
    private let launchGate: AutoFillLaunchGate
    private let maximumConnections: Int
    private let idleTimeout: TimeInterval
    private let verifier: @Sendable (Int32) throws -> VerifiedAutoFillPeer
    private let requestHandler: AutoFillBrokerRequestHandler
    private let candidateHandler: AutoFillBrokerCandidateHandler
    private nonisolated let activeConnections = OSAllocatedUnfairLock(initialState: Set<Int32>())

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(
        listenPath: String,
        registry: AutoFillRequestRegistry,
        launchGate: AutoFillLaunchGate,
        maximumConnections: Int = 32,
        idleTimeout: TimeInterval = 30,
        verifier: @escaping @Sendable (Int32) throws -> VerifiedAutoFillPeer = { fd in
            try AutoFillPeerVerifier.verify(
                fd: fd,
                expectedIdentifier: AutoFillConstants.extensionBundleIdentifier,
                teamID: "H23TXL6LPT"
            )
        },
        requestHandler: @escaping AutoFillBrokerRequestHandler,
        candidateHandler: @escaping AutoFillBrokerCandidateHandler
    ) {
        self.listenPath = listenPath
        self.registry = registry
        self.launchGate = launchGate
        self.maximumConnections = max(1, maximumConnections)
        self.idleTimeout = min(max(idleTimeout, 0.01), 30)
        self.verifier = verifier
        self.requestHandler = requestHandler
        self.candidateHandler = candidateHandler
    }

    func start() throws {
        guard acceptSource == nil, serverFD < 0 else { throw AutoFillBrokerError.alreadyStarted }
        guard listenPath.utf8.count < SSHAgentConstants.maxSocketPathLength else {
            throw AutoFillBrokerError.invalidSocketPath
        }

        let fd = try createListeningSocket()
        serverFD = fd

        let dependencies = AutoFillBrokerConnectionProcessor.Dependencies(
            registry: registry,
            launchGate: launchGate,
            verifier: verifier,
            requestHandler: requestHandler,
            candidateHandler: candidateHandler
        )
        let connectionLimit = maximumConnections
        let readTimeout = idleTimeout
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [activeConnections] in
            Self.acceptAvailableConnections(
                serverFD: fd,
                maximumConnections: connectionLimit,
                idleTimeout: readTimeout,
                dependencies: dependencies,
                activeConnections: activeConnections
            )
        }
        source.setCancelHandler {}
        source.resume()
        acceptSource = source
    }

    func stop() async {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        activeConnections.withLock { descriptors in
            for descriptor in descriptors {
                Darwin.shutdown(descriptor, SHUT_RDWR)
            }
        }
        unlink(listenPath)

        for _ in 0..<100 where activeConnections.withLock(\.isEmpty) == false {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func activeConnectionCount() -> Int {
        activeConnections.withLock(\.count)
    }

    private func createListeningSocket() throws -> Int32 {
        let directory = (listenPath as NSString).deletingLastPathComponent
        var directoryMetadata = stat()
        if lstat(directory, &directoryMetadata) != 0 {
            guard errno == ENOENT else { throw AutoFillBrokerError.socketSetupFailed }
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw AutoFillBrokerError.socketSetupFailed
            }
        }
        guard lstat(directory, &directoryMetadata) == 0,
              directoryMetadata.st_uid == getuid(),
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              chmod(directory, 0o700) == 0 else {
            throw AutoFillBrokerError.socketSetupFailed
        }

        unlink(listenPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutoFillBrokerError.socketSetupFailed }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            throw AutoFillBrokerError.socketSetupFailed
        }

        var address = SSHAgentConstants.makeUnixAddr(path: listenPath)
        let previousUmask = umask(0o077)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousUmask)

        guard bindResult == 0,
              chmod(listenPath, 0o600) == 0,
              listen(fd, Int32(maximumConnections)) == 0 else {
            close(fd)
            unlink(listenPath)
            throw AutoFillBrokerError.socketSetupFailed
        }
        return fd
    }

    private nonisolated static func acceptAvailableConnections(
        serverFD: Int32,
        maximumConnections: Int,
        idleTimeout: TimeInterval,
        dependencies: AutoFillBrokerConnectionProcessor.Dependencies,
        activeConnections: OSAllocatedUnfairLock<Set<Int32>>
    ) {
        while true {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                return
            }

            let admitted = activeConnections.withLock { descriptors in
                guard descriptors.count < maximumConnections else { return false }
                descriptors.insert(clientFD)
                return true
            }
            guard admitted else {
                close(clientFD)
                continue
            }

            AutoFillBrokerConnectionProcessor.configureAcceptedSocket(clientFD, idleTimeout: idleTimeout)
            Task.detached(priority: .userInitiated) {
                defer {
                    _ = activeConnections.withLock { $0.remove(clientFD) }
                    Darwin.close(clientFD)
                }
                await AutoFillBrokerConnectionProcessor.processConnection(
                    fd: clientFD,
                    dependencies: dependencies
                )
            }
        }
    }
}
