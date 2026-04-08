import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("SSHAgentProtocol Tests")
struct SSHAgentProtocolTests {

    // MARK: - Message Type

    @Test("message types have correct raw values")
    func messageTypeRawValues() {
        #expect(SSHAgentMessageType.failure.rawValue == 5)
        #expect(SSHAgentMessageType.success.rawValue == 6)
        #expect(SSHAgentMessageType.requestIdentities.rawValue == 11)
        #expect(SSHAgentMessageType.identitiesAnswer.rawValue == 12)
        #expect(SSHAgentMessageType.signRequest.rawValue == 13)
        #expect(SSHAgentMessageType.signResponse.rawValue == 14)
        #expect(SSHAgentMessageType.unknown.rawValue == 255)
    }

    // MARK: - Parse request identities

    @Test("parses request identities message")
    func parseRequestIdentities() throws {
        // [4 bytes length = 1] [1 byte type = 11] — no payload
        var data = Data()
        data.append(contentsOf: UInt32(1).bigEndianBytes)
        data.append(SSHAgentMessageType.requestIdentities.rawValue)

        let message = try SSHAgentMessage.parse(from: data)
        #expect(message.type == .requestIdentities)
        #expect(message.payload.isEmpty)
    }

    // MARK: - Parse sign request

    @Test("parses sign request message with key blob and data")
    func parseSignRequest() throws {
        let keyBlob = Data([0x00, 0x01, 0x02, 0x03])
        let signData = Data([0xAA, 0xBB, 0xCC])
        let flags: UInt32 = 2

        var payload = Data()
        payload.append(contentsOf: UInt32(keyBlob.count).bigEndianBytes)
        payload.append(keyBlob)
        payload.append(contentsOf: UInt32(signData.count).bigEndianBytes)
        payload.append(signData)
        payload.append(contentsOf: flags.bigEndianBytes)

        var data = Data()
        data.append(contentsOf: UInt32(1 + UInt32(payload.count)).bigEndianBytes)
        data.append(SSHAgentMessageType.signRequest.rawValue)
        data.append(payload)

        let message = try SSHAgentMessage.parse(from: data)
        #expect(message.type == .signRequest)
        #expect(message.keyBlob == keyBlob)
    }

    // MARK: - Failure response

    @Test("creates failure response")
    func failureResponse() {
        let response = SSHAgentMessage.failureResponse()
        // Should be [4 bytes: length=1] [1 byte: type=5]
        #expect(response.count == 5)
        let length = response.readUInt32(at: 0)
        #expect(length == 1)
        #expect(response[4] == SSHAgentMessageType.failure.rawValue)
    }

    // MARK: - Serialize

    @Test("serializes message with type and payload")
    func serialize() {
        let payload = Data([0x01, 0x02, 0x03])
        let message = SSHAgentMessage(type: .success, payload: payload)
        let serialized = message.serialize()

        // [4 bytes length = 1 + 3 = 4] [1 byte type = 6] [3 bytes payload]
        #expect(serialized.count == 8)
        let length = serialized.readUInt32(at: 0)
        #expect(length == 4)
        #expect(serialized[4] == SSHAgentMessageType.success.rawValue)
        #expect(serialized.subdata(in: 5..<8) == payload)
    }

    // MARK: - Read from stream (using Pipe as FileHandle stand-in)

    @Test("reads message from FileHandle stream")
    func readFromStream() throws {
        let pipe = Pipe()
        let payload = Data([0xDE, 0xAD])
        var wireData = Data()
        wireData.append(contentsOf: UInt32(1 + UInt32(payload.count)).bigEndianBytes)
        wireData.append(SSHAgentMessageType.requestIdentities.rawValue)
        wireData.append(payload)

        pipe.fileHandleForWriting.write(wireData)
        pipe.fileHandleForWriting.closeFile()

        let message = try SSHAgentMessage.read(from: pipe.fileHandleForReading)
        #expect(message.type == .requestIdentities)
        #expect(message.payload == payload)
    }

    @Test("read from empty stream throws unexpectedEOF")
    func readFromEmptyStream() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.closeFile()

        #expect(throws: SSHAgentError.unexpectedEOF) {
            _ = try SSHAgentMessage.read(from: pipe.fileHandleForReading)
        }
    }

    // MARK: - Parse identities response

    @Test("parses identities answer payload")
    func parseIdentitiesResponse() throws {
        let keyBlob1 = Data([0x01, 0x02])
        let comment1 = "my-key"
        let keyBlob2 = Data([0x03, 0x04, 0x05])
        let comment2 = "other-key"

        var payload = Data()
        // nkeys = 2
        payload.append(contentsOf: UInt32(2).bigEndianBytes)
        // key 1
        payload.append(contentsOf: UInt32(keyBlob1.count).bigEndianBytes)
        payload.append(keyBlob1)
        let comment1Data = comment1.data(using: .utf8)!
        payload.append(contentsOf: UInt32(comment1Data.count).bigEndianBytes)
        payload.append(comment1Data)
        // key 2
        payload.append(contentsOf: UInt32(keyBlob2.count).bigEndianBytes)
        payload.append(keyBlob2)
        let comment2Data = comment2.data(using: .utf8)!
        payload.append(contentsOf: UInt32(comment2Data.count).bigEndianBytes)
        payload.append(comment2Data)

        let message = SSHAgentMessage(type: .identitiesAnswer, payload: payload)
        let identities = try message.parseIdentities()

        #expect(identities.count == 2)
        #expect(identities[0].keyBlob == keyBlob1)
        #expect(identities[0].comment == "my-key")
        #expect(identities[1].keyBlob == keyBlob2)
        #expect(identities[1].comment == "other-key")
    }

    // MARK: - Error cases

    @Test("parse rejects message shorter than 5 bytes")
    func parseTooShort() {
        let data = Data([0x00, 0x00])
        #expect(throws: SSHAgentError.messageTooShort) {
            _ = try SSHAgentMessage.parse(from: data)
        }
    }

    @Test("parse rejects message exceeding 256KB")
    func parseTooLarge() {
        var data = Data()
        let hugeLength: UInt32 = 300_000
        data.append(contentsOf: hugeLength.bigEndianBytes)
        data.append(SSHAgentMessageType.requestIdentities.rawValue)
        data.append(Data(repeating: 0, count: Int(hugeLength) - 1))

        #expect(throws: SSHAgentError.messageTooLarge) {
            _ = try SSHAgentMessage.parse(from: data)
        }
    }

    // MARK: - Data.readUInt32 extension

    @Test("readUInt32 reads big-endian uint32 at offset")
    func readUInt32() {
        let data = Data([0x00, 0x00, 0x01, 0x00]) // 256 in big-endian
        #expect(data.readUInt32(at: 0) == 256)
    }
}

// MARK: - Test helpers

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        return withUnsafeBytes(of: be) { Array($0) }
    }
}
