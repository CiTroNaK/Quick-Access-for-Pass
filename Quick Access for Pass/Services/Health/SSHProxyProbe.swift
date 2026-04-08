import Foundation
import Darwin
import os

nonisolated enum SSHProbeResult: Sendable, Equatable {
    case healthy(identityCount: Int)
    case emptyIdentities
    case unreachable(SSHProbeFailure)
}

nonisolated enum SSHProbeFailure: Sendable, Equatable {
    case connectFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed
    case parseFailed
}

/// End-to-end health probe for the SSH proxy chain. Connects to our own listen socket,
/// which forces runClientLoop to connect to upstream. One probe validates the whole chain.
nonisolated enum SSHProxyProbe {
    static func listIdentities(
        at listenPath: String,
        timeout: TimeInterval = 2.0
    ) async -> SSHProbeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: Self.blockingListIdentities(listenPath: listenPath, timeout: timeout))
            }
        }
    }

    private static func blockingListIdentities(listenPath: String, timeout: TimeInterval) -> SSHProbeResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable(.connectFailed(errno: errno)) }
        defer { close(fd) }

        let wholeSeconds = Int(timeout)
        let microseconds = Int((timeout - Double(wholeSeconds)) * 1_000_000)
        var timeoutSpec: timeval = .init(
            tv_sec: __darwin_time_t(wholeSeconds),
            tv_usec: __darwin_suseconds_t(microseconds)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeoutSpec, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeoutSpec, socklen_t(MemoryLayout<timeval>.size))

        // Capture errno immediately inside the syscall closure to avoid stale thread-local reads.
        var addr = SSHAgentConstants.makeUnixAddr(path: listenPath)
        var connectErrno: Int32 = 0
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                let result = Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                if result != 0 { connectErrno = errno }
                return result
            }
        }
        guard connectResult == 0 else {
            AppLogger.probe.error("ssh probe connect failed errno=\(connectErrno, privacy: .public) path=\(listenPath, privacy: .private(mask: .hash))")
            return .unreachable(.connectFailed(errno: connectErrno))
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)

        let request = SSHAgentMessage(type: .requestIdentities, payload: Data())
        do {
            try handle.writeAll(request.serialize())
        } catch {
            let writeErrno = errno
            AppLogger.probe.error("ssh probe write failed errno=\(writeErrno, privacy: .public)")
            return .unreachable(.writeFailed(errno: writeErrno))
        }

        let response: SSHAgentMessage
        do {
            response = try SSHAgentMessage.read(from: handle)
        } catch {
            AppLogger.probe.error("ssh probe read failed")
            return .unreachable(.readFailed)
        }

        guard response.type == .identitiesAnswer else {
            AppLogger.probe.error("ssh probe unexpected response rawType=\(response.rawType, privacy: .public)")
            return .unreachable(.parseFailed)
        }

        let identities: [SSHAgentIdentity]
        do {
            identities = try response.parseIdentities()
        } catch {
            AppLogger.probe.error("ssh probe parseIdentities failed")
            return .unreachable(.parseFailed)
        }

        return identities.isEmpty ? .emptyIdentities : .healthy(identityCount: identities.count)
    }
}
