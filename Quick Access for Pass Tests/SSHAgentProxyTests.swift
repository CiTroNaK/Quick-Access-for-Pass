import Testing
import Foundation
@testable import Quick_Access_for_Pass

// MARK: - Test Helpers

/// A minimal socket server that accepts one connection, reads a message, and sends a fixed response.
private final class TestSocketServer: @unchecked Sendable {
    let path: String
    private var serverFd: Int32 = -1
    private var thread: Thread?
    private let responseProvider: @Sendable (SSHAgentMessage) -> Data

    init(path: String, responseProvider: @escaping @Sendable (SSHAgentMessage) -> Data) {
        self.path = path
        self.responseProvider = responseProvider
    }

    func start() throws {
        unlink(path)

        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else { throw SSHAgentError.socketBindFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(path.utf8.count, 104))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFd)
            throw SSHAgentError.socketBindFailed
        }

        guard listen(serverFd, 5) == 0 else {
            close(serverFd)
            throw SSHAgentError.socketBindFailed
        }

        let fd = serverFd
        let provider = responseProvider
        thread = Thread {
            while true {
                let clientFd = accept(fd, nil, nil)
                guard clientFd >= 0 else { break }

                let handle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: false)
                defer {
                    close(clientFd)
                }

                // Handle messages in a loop
                while true {
                    guard let message = try? SSHAgentMessage.read(from: handle) else { break }
                    let response = provider(message)
                    handle.write(response)
                }
            }
        }
        thread?.start()
    }

    func stop() {
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(path)
    }
}

/// A minimal socket client that connects to a Unix socket, sends data, and reads a response.
private final class TestSocketClient: @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1

    init(path: String) {
        self.path = path
    }

    func connect() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHAgentError.connectionFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(path.utf8.count, 104))
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            fd = -1
            throw SSHAgentError.connectionFailed
        }
    }

    func send(_ data: Data) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        handle.write(data)
    }

    func readMessage() throws -> SSHAgentMessage {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try SSHAgentMessage.read(from: handle)
    }

    func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

// MARK: - Tests

@Suite("SSHAgentProxy Tests")
struct SSHAgentProxyTests {

    // MARK: - Start and Stop

    @Test("proxy starts and stops cleanly")
    func startAndStop() async throws {
        let socketPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"

        let proxy = SSHAgentProxy(
            listenPath: socketPath,
            upstreamPath: "/dev/null",
            authorizationHandler: { _, _ in .allow },
            failureSignal: { _ in }
        )

        try await proxy.start()

        #expect(FileManager.default.fileExists(atPath: socketPath))

        await proxy.stop()

        #expect(FileManager.default.fileExists(atPath: socketPath) == false)
    }

    // MARK: - Request Identities Pass Through

    @Test("request identities passes through to upstream")
    func requestIdentitiesPassThrough() async throws {
        let upstreamPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let proxyPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"

        var identitiesPayload = Data()
        identitiesPayload.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Array($0) })
        let identitiesResponse = SSHAgentMessage(
            type: .identitiesAnswer,
            payload: identitiesPayload
        ).serialize()

        let upstream = TestSocketServer(path: upstreamPath) { _ in identitiesResponse }
        try upstream.start()
        defer { upstream.stop() }

        let proxy = SSHAgentProxy(
            listenPath: proxyPath,
            upstreamPath: upstreamPath,
            authorizationHandler: { _, _ in .allow },
            failureSignal: { _ in }
        )
        try await proxy.start()

        do {
            let client = TestSocketClient(path: proxyPath)
            try client.connect()
            defer { client.disconnect() }

            let requestMessage = SSHAgentMessage(type: .requestIdentities, payload: Data())
            client.send(requestMessage.serialize())

            let response = try client.readMessage()
            #expect(response.type == .identitiesAnswer)

            let identities = try response.parseIdentities()
            #expect(identities.isEmpty)
        } catch {
            await proxy.stop()
            throw error
        }
        await proxy.stop()
    }

    // MARK: - Sign Request Denied

    @Test("sign request denied returns failure")
    func signRequestDenied() async throws {
        let upstreamPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let proxyPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"

        let upstream = TestSocketServer(path: upstreamPath) { _ in
            SSHAgentMessage.failureResponse()
        }
        try upstream.start()
        defer { upstream.stop() }

        let proxy = SSHAgentProxy(
            listenPath: proxyPath,
            upstreamPath: upstreamPath,
            authorizationHandler: { _, _ in .deny },
            failureSignal: { _ in }
        )
        try await proxy.start()

        do {
            let client = TestSocketClient(path: proxyPath)
            try client.connect()
            defer { client.disconnect() }

            let keyBlob = Data([0x00, 0x01, 0x02, 0x03])
            let signData = Data([0xAA, 0xBB])
            let flags: UInt32 = 0

            var payload = Data()
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(keyBlob.count).bigEndian) { Array($0) })
            payload.append(keyBlob)
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(signData.count).bigEndian) { Array($0) })
            payload.append(signData)
            payload.append(contentsOf: withUnsafeBytes(of: flags.bigEndian) { Array($0) })

            let signMessage = SSHAgentMessage(type: .signRequest, payload: payload)
            client.send(signMessage.serialize())

            let response = try client.readMessage()
            #expect(response.type == .failure)
        } catch {
            await proxy.stop()
            throw error
        }
        await proxy.stop()
    }

    @Test("sign request allowed forwards to upstream and returns signature")
    func signRequestAllowed() async throws {
        let upstreamPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"
        let proxyPath = NSTemporaryDirectory() + UUID().uuidString + ".sock"

        // Canned signature response bytes. The exact bytes don't matter —
        // we just verify that whatever upstream sends flows back to
        // the client unchanged.
        let signatureBlob = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        var signaturePayload = Data()
        signaturePayload.append(contentsOf: withUnsafeBytes(of: UInt32(signatureBlob.count).bigEndian) { Array($0) })
        signaturePayload.append(signatureBlob)
        let signatureResponse = SSHAgentMessage(
            type: .signResponse,
            payload: signaturePayload
        ).serialize()

        let upstream = TestSocketServer(path: upstreamPath) { request in
            if request.type == .signRequest {
                return signatureResponse
            }
            return SSHAgentMessage.failureResponse()
        }
        try upstream.start()
        defer { upstream.stop() }

        let proxy = SSHAgentProxy(
            listenPath: proxyPath,
            upstreamPath: upstreamPath,
            authorizationHandler: { _, _ in .allow },
            failureSignal: { _ in }
        )
        try await proxy.start()

        do {
            let client = TestSocketClient(path: proxyPath)
            try client.connect()
            defer { client.disconnect() }

            // Build sign request
            let keyBlob = Data([0x00, 0x01, 0x02, 0x03])
            let signData = Data([0xAA, 0xBB])
            let flags: UInt32 = 0

            var payload = Data()
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(keyBlob.count).bigEndian) { Array($0) })
            payload.append(keyBlob)
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(signData.count).bigEndian) { Array($0) })
            payload.append(signData)
            payload.append(contentsOf: withUnsafeBytes(of: flags.bigEndian) { Array($0) })

            let signMessage = SSHAgentMessage(type: .signRequest, payload: payload)
            client.send(signMessage.serialize())

            let response = try client.readMessage()
            #expect(response.type == .signResponse)

            // Verify the full payload was forwarded unchanged
            #expect(response.payload == signaturePayload)
        } catch {
            await proxy.stop()
            throw error
        }
        await proxy.stop()
    }
}
