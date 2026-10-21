import Darwin
import Foundation
import os

nonisolated final class SocketAutoFillBrokerClientConnection: AutoFillBrokerClientConnection, Sendable {
    private let descriptor = OSAllocatedUnfairLock(initialState: Int32(-1))
    private let verifier: @Sendable (Int32) throws -> VerifiedAutoFillPeer

    init(
        socketPath: String,
        verifier: @escaping @Sendable (Int32) throws -> VerifiedAutoFillPeer
    ) throws {
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw AutoFillBrokerClientError.unavailable
        }
        self.verifier = verifier

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutoFillBrokerClientError.unavailable }
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))

        var address = Self.makeUnixAddress(path: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw AutoFillBrokerClientError.unavailable
        }
        descriptor.withLock { $0 = fd }
    }

    func verifyHost() throws {
        let fd = try openDescriptor()
        _ = try verifier(fd)
    }

    func exchange(_ request: AutoFillBrokerRequest) throws -> AutoFillBrokerResponse {
        let fd = try openDescriptor()
        try configureTimeout(fd: fd, deadline: request.deadlineUptimeNanoseconds)
        do {
            try AutoFillWire.writeMessage(request, toFileDescriptor: fd)
            return try AutoFillWire.readMessage(
                AutoFillBrokerResponse.self,
                fromFileDescriptor: fd
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AutoFillBrokerClientError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AutoFillBrokerClientError.invalidResponse
        }
    }

    func close() {
        let fd = descriptor.withLock { descriptor in
            let fd = descriptor
            descriptor = -1
            return fd
        }
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func openDescriptor() throws -> Int32 {
        let fd = descriptor.withLock { $0 }
        guard fd >= 0 else {
            if Task.isCancelled { throw CancellationError() }
            throw AutoFillBrokerClientError.invalidResponse
        }
        return fd
    }

    private func configureTimeout(fd: Int32, deadline: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { throw AutoFillBrokerClientError.expired }
        let remaining = deadline - now
        var timeout = timeval(
            tv_sec: Int(remaining / 1_000_000_000),
            tv_usec: Int32((remaining % 1_000_000_000) / 1_000)
        )
        if timeout.tv_sec == 0, timeout.tv_usec == 0 { timeout.tv_usec = 1 }
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw AutoFillBrokerClientError.invalidResponse
        }
    }

    private static func makeUnixAddress(path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: path.utf8)
        }
        return address
    }
}
