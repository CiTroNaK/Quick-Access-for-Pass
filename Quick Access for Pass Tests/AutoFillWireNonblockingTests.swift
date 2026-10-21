import Darwin
import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill nonblocking wire", .timeLimit(.minutes(1)))
struct AutoFillWireNonblockingTests {
    @Test("blocking descriptors fail closed before any credential frame bytes")
    func blockingDescriptorIsRejectedBeforeWritingFrameBytes() throws {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        defer { close(pair[0]); close(pair[1]) }
        var sendBuffer: Int32 = 1024
        guard setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        // Bound the old blocking implementation so its RED cannot wedge the
        // test host. Correct code rejects this descriptor without sending.
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        guard setsockopt(pair[0], SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              fcntl(pair[1], F_SETFL, fcntl(pair[1], F_GETFL) | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        let response = AutoFillBrokerResponse.credential(
            requestID: UUID(), value: String(repeating: "x", count: AutoFillWire.maximumMessageSize - 256)
        )
        #expect(throws: AutoFillProtocolError.connectionClosed) {
            try AutoFillWire.writeMessageNonblocking(response, toFileDescriptor: pair[0])
        }
        var byte: UInt8 = 0
        let received = recv(pair[1], &byte, 1, 0)
        let receiveError = errno
        #expect(received == -1)
        #expect(receiveError == EAGAIN || receiveError == EWOULDBLOCK)
        #expect(fcntl(pair[0], F_GETFD) >= 0)
        #expect(fcntl(pair[0], F_GETFL) & O_NONBLOCK == 0)
    }
}
