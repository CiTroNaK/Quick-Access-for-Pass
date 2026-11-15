import Darwin
import Foundation
import os

/// Sends one read-only `terminal.get` request to a Herdr Core socket whose peer is verified as Core.
nonisolated protocol HerdrCoreSocketQuerying: Sendable {
    func terminalGet(socketPath: String, terminalID: String, deadline: CLIExecutionDeadline) async throws -> Data
}

nonisolated enum HerdrCoreSocketError: Error, Equatable {
    case connectFailed
    case peerNotCore
    case ioFailed
    case responseTooLarge
}

nonisolated struct LiveHerdrCoreSocketClient: HerdrCoreSocketQuerying {
    static let maximumResponseBytes = 512 * 1024

    private let verifier: any HerdrCodeSignatureVerifying
    private let now: @Sendable () -> UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(verifier: any HerdrCodeSignatureVerifying,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.verifier = verifier
        self.now = now
        self.sleep = sleep
    }

    static func requestLine(terminalID: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var line = Data(#"{"jsonrpc":"2.0","id":1,"method":"terminal.get","params":{"terminal":"#.utf8)
        line.append(try encoder.encode(terminalID))
        line.append(Data("}}\n".utf8))
        return line
    }

    /// Connect, verify the peer, then exchange one line. Socket I/O runs on worker threads bounded by poll;
    /// the peer's signature check is awaited only within the deadline. Nothing is written before it passes.
    func terminalGet(socketPath: String, terminalID: String, deadline: CLIExecutionDeadline) async throws -> Data {
        let request = try Self.requestLine(terminalID: terminalID)
        let connection = Connection()
        // Every worker step below has returned by now, so closing here never races a blocking call.
        defer { connection.close() }
        let verifier = verifier
        let now = now
        return try await withTaskCancellationHandler {
            let token = try await Self.onWorker { try connection.open(socketPath: socketPath, deadline: deadline, now: now) }
            let remaining = (try? deadline.remainingSeconds(at: now())).map { UInt64($0 * 1_000_000_000) } ?? 0
            let peerCheck = BoundedBlockingWork { verifier.isVerifiedCore(auditToken: token) }
            switch await peerCheck.value(within: remaining, sleep: sleep) {
            case true?: break
            case false?: throw HerdrCoreSocketError.peerNotCore
            case nil:
                try Task.checkCancellation()
                throw CLIError.timeout
            }
            return try await Self.onWorker { try connection.exchange(request, deadline: deadline, now: now) }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func onWorker<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

/// One connection driven in steps. Only `close()` closes the descriptor, after every step has returned;
/// cancellation merely shuts it down while it is known to be open, so a reused descriptor number is never touched.
nonisolated private final class Connection: Sendable {
    private let state = OSAllocatedUnfairLock<(fd: Int32?, cancelled: Bool)>(initialState: (nil, false))

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            if let fd = state.fd { shutdown(fd, SHUT_RDWR) }
        }
    }

    func close() {
        if let fd = state.withLock({ state -> Int32? in defer { state.fd = nil }; return state.fd }) { Darwin.close(fd) }
    }

    /// Connects within the deadline and returns the peer's audit token.
    func open(socketPath: String, deadline: CLIExecutionDeadline, now: @Sendable () -> UInt64) throws -> audit_token_t {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrCoreSocketError.connectFailed }
        let registered = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.fd = fd
            return true
        }
        guard registered else {
            Darwin.close(fd)
            throw CancellationError()
        }
        // A peer that closes mid-write must produce EPIPE, not kill the process.
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw HerdrCoreSocketError.connectFailed }
        try connect(fd, socketPath: socketPath, deadline: deadline, now: now)
        guard let token = LocalPeerToken.read(fd: fd) else { throw HerdrCoreSocketError.peerNotCore }
        return token
    }

    /// Writes the request and reads one reply line. Call only after the peer has been verified.
    func exchange(_ request: Data, deadline: CLIExecutionDeadline, now: @Sendable () -> UInt64) throws -> Data {
        guard let fd = state.withLock({ $0.fd }) else { throw HerdrCoreSocketError.ioFailed }
        try write(fd, request, deadline: deadline, now: now)
        return try readLine(fd, deadline: deadline, now: now)
    }

    private func connect(_ fd: Int32, socketPath: String, deadline: CLIExecutionDeadline, now: () -> UInt64) throws {
        var address = SSHAgentConstants.makeUnixAddr(path: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS else { throw HerdrCoreSocketError.connectFailed }
        try wait(fd, for: Int16(POLLOUT), deadline: deadline, now: now)
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
            throw HerdrCoreSocketError.connectFailed
        }
    }

    private func write(_ fd: Int32, _ data: Data, deadline: CLIExecutionDeadline, now: () -> UInt64) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, for: Int16(POLLOUT), deadline: deadline, now: now)
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                continue
            } else {
                throw HerdrCoreSocketError.ioFailed
            }
        }
    }

    private func readLine(_ fd: Int32, deadline: CLIExecutionDeadline, now: () -> UInt64) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try wait(fd, for: Int16(POLLIN), deadline: deadline, now: now)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            if count == 0 {
                // A complete reply may end at a clean close instead of a newline; the decoder still validates it.
                guard !response.isEmpty else { throw HerdrCoreSocketError.ioFailed }
                return response
            }
            guard count > 0 else { throw HerdrCoreSocketError.ioFailed }
            if let newline = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                response.append(contentsOf: buffer[..<newline])
                guard response.count <= LiveHerdrCoreSocketClient.maximumResponseBytes else {
                    throw HerdrCoreSocketError.responseTooLarge
                }
                return response
            }
            response.append(contentsOf: buffer[..<count])
            guard response.count <= LiveHerdrCoreSocketClient.maximumResponseBytes else {
                throw HerdrCoreSocketError.responseTooLarge
            }
        }
    }

    private func wait(_ fd: Int32, for events: Int16, deadline: CLIExecutionDeadline, now: () -> UInt64) throws {
        while true {
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
            let remaining = try deadline.remainingSeconds(at: now())
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000).rounded(.up)))
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
            if result > 0 { return }
            if result < 0, errno != EINTR { throw HerdrCoreSocketError.ioFailed }
        }
    }
}
