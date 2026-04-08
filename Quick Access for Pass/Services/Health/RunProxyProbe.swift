import Foundation
import Darwin
import os

nonisolated enum RunProbeResult: Sendable, Equatable {
    case healthy
    case unreachable(RunProbeFailure)
}

nonisolated enum RunProbeFailure: Sendable, Equatable {
    case connectFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case invalidResponse
}

/// Round-trip liveness probe for the Run proxy listen socket. Sends a real
/// `RunProxyRequest` with the reserved ping slug, reads the response, and
/// verifies it is an `.allow`. This proves the full chain is alive: kernel
/// accept backlog → RunProxy accept loop → handleClient dispatch → wire
/// read/write. pass-cli login health is covered separately by
/// `PassCLISanityCheck` at discrete events (launch, wake, Settings-window open).
nonisolated enum RunProxyProbe {
    static func ping(
        at socketPath: String,
        timeout: TimeInterval = 2.0
    ) async -> RunProbeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: Self.blockingPing(socketPath: socketPath, timeout: timeout))
            }
        }
    }

    private static func blockingPing(socketPath: String, timeout: TimeInterval) -> RunProbeResult {
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

        var addr = SSHAgentConstants.makeUnixAddr(path: socketPath)
        var connectErrno: Int32 = 0
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                let result = Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                if result != 0 { connectErrno = errno }
                return result
            }
        }
        guard connectResult == 0 else {
            AppLogger.probe.error("run probe connect failed errno=\(connectErrno, privacy: .public) path=\(socketPath, privacy: .private(mask: .hash))")
            return .unreachable(.connectFailed(errno: connectErrno))
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)

        let ping = RunProxyRequest(
            profile: RunProxyProbeConstants.reservedPingSlug,
            command: [],
            pid: 0
        )

        do {
            try RunProxyWire.writeMessage(ping, to: handle)
        } catch {
            let capturedErrno = errno
            AppLogger.probe.error("run probe write failed errno=\(capturedErrno, privacy: .public)")
            return .unreachable(.writeFailed(errno: capturedErrno))
        }

        let response: RunProxyResponse
        do {
            response = try RunProxyWire.readMessage(RunProxyResponse.self, from: handle)
        } catch {
            let capturedErrno = errno
            AppLogger.probe.error("run probe read failed errno=\(capturedErrno, privacy: .public)")
            return .unreachable(.readFailed(errno: capturedErrno))
        }

        guard response.decision == .allow else {
            AppLogger.probe.error("run probe invalid response decision=\(String(describing: response.decision), privacy: .public)")
            return .unreachable(.invalidResponse)
        }

        return .healthy
    }
}
