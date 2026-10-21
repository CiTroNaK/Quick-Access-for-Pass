import Darwin
import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Broker fixture socket deadline behavior", .serialized)
nonisolated struct AutoFillBrokerSocketIOTests {
    @Test("Raw EOF capture survives an idle poll while the original request remains valid")
    func rawCaptureHonorsOriginalDeadline() async throws {
        let (reader, writer) = try socketPair()
        defer { close(reader) }
        let expected = AutoFillBrokerResponse.credential(requestID: UUID(), value: "fixture-value")
        async let sent: Void = nativeWrite(to: writer) {
            // Native fixture work is independent of the UI executor being tested elsewhere.
            Thread.sleep(forTimeInterval: 1.2)
            try AutoFillWire.writeMessage(expected, toFileDescriptor: writer)
        }
        do {
            let bytes = try await BrokerTestSocketIO.readUntilEOF(from: reader, makeDeadline: {
                DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            })
            try await sent
            #expect(bytes.count > 4)
            let response = try JSONDecoder().decode(AutoFillBrokerResponse.self, from: Data(bytes.dropFirst(4)))
            #expect(response == expected)
        } catch {
            try? await sent
            throw error
        }
    }

    @Test("Partial byte progress never resets the raw capture's original deadline")
    func partialProgressDoesNotExtendDeadline() async throws {
        let (reader, writer) = try socketPair()
        defer { close(reader) }
        async let sent: Void = nativeWrite(to: writer) {
            var byte: UInt8 = 17
            for _ in 0..<120 {
                guard Darwin.write(writer, &byte, 1) == 1 else { throw POSIXError(.EIO) }
                usleep(10_000)
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000
        await #expect(throws: POSIXError(.ETIMEDOUT)) {
            try await BrokerTestSocketIO.readUntilEOF(from: reader, deadlineUptimeNanoseconds: deadline)
        }
        try await sent
    }

    private func socketPair() throws -> (Int32, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        return (descriptors[0], descriptors[1])
    }

    private func nativeWrite(to descriptor: Int32, body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue(label: "tests.broker-socket-peer", qos: .userInitiated).async {
                defer { close(descriptor) }
                do {
                    try body()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
