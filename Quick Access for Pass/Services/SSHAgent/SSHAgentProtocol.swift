import Foundation

// MARK: - Message Types

nonisolated enum SSHAgentMessageType: UInt8, Sendable {
    case failure = 5
    case success = 6
    case requestIdentities = 11
    case identitiesAnswer = 12
    case signRequest = 13
    case signResponse = 14
    case unknown = 255
}

// MARK: - Identity

nonisolated struct SSHAgentIdentity: Sendable, Equatable {
    let keyBlob: Data
    let comment: String
}

// MARK: - Errors

nonisolated enum SSHAgentError: Error, Equatable, Sendable {
    case messageTooShort
    case messageTooLarge
    case unexpectedEOF
    case unexpectedMessageType
    case connectionFailed
    case socketBindFailed
    case socketPathTooLong(String)
}

// MARK: - Message

nonisolated struct SSHAgentMessage: Sendable {
    /// Maximum allowed message payload size (256 KB).
    static let maxMessageLength: UInt32 = 256 * 1024

    let type: SSHAgentMessageType
    /// The original wire type byte, preserved for lossless forwarding of unknown message types.
    let rawType: UInt8
    let payload: Data

    init(type: SSHAgentMessageType, payload: Data) {
        self.type = type
        self.rawType = type.rawValue
        self.payload = payload
    }

    private init(type: SSHAgentMessageType, rawType: UInt8, payload: Data) {
        self.type = type
        self.rawType = rawType
        self.payload = payload
    }

    /// Extracts the key blob from a sign-request payload.
    /// Sign request payload: [4-byte key_blob length] [key_blob] [4-byte data length] [data] [4-byte flags]
    var keyBlob: Data? {
        guard payload.count >= 4 else { return nil }
        let blobLength = payload.readUInt32(at: 0)
        let start = 4
        let end = start + Int(blobLength)
        guard end <= payload.count else { return nil }
        return payload.subdata(in: start..<end)
    }

    // MARK: - Parse from raw data

    /// Parses a complete wire-format message: [4-byte length] [1-byte type] [payload].
    static func parse(from data: Data) throws -> SSHAgentMessage {
        guard data.count >= 5 else {
            throw SSHAgentError.messageTooShort
        }

        let length = data.readUInt32(at: 0)
        guard length <= maxMessageLength else {
            throw SSHAgentError.messageTooLarge
        }

        let typeByte = data[4]
        let messageType = SSHAgentMessageType(rawValue: typeByte) ?? .unknown

        let payloadStart = 5
        let payloadEnd = 4 + Int(length)
        let payload: Data
        if payloadEnd > payloadStart {
            guard payloadEnd <= data.count else {
                throw SSHAgentError.messageTooShort
            }
            payload = data.subdata(in: payloadStart..<payloadEnd)
        } else {
            payload = Data()
        }

        return SSHAgentMessage(type: messageType, rawType: typeByte, payload: payload)
    }

    // MARK: - Read from FileHandle

    /// Reads one complete message from a FileHandle (blocking I/O).
    static func read(from handle: FileHandle) throws -> SSHAgentMessage {
        let lengthData = try handle.readExact(count: 4)
        let length = lengthData.readUInt32(at: 0)

        guard length <= maxMessageLength else {
            throw SSHAgentError.messageTooLarge
        }
        guard length >= 1 else {
            throw SSHAgentError.messageTooShort
        }

        let body = try handle.readExact(count: Int(length))
        let typeByte = body[0]
        let messageType = SSHAgentMessageType(rawValue: typeByte) ?? .unknown
        let payload = body.count > 1 ? body.subdata(in: 1..<body.count) : Data()

        return SSHAgentMessage(type: messageType, rawType: typeByte, payload: payload)
    }

    // MARK: - Serialize

    /// Serializes to wire format: [4-byte length] [1-byte type] [payload].
    /// Uses `rawType` to preserve the original type byte for unknown message types.
    func serialize() -> Data {
        let length = UInt32(1 + payload.count)
        var data = Data(capacity: 4 + Int(length))
        data.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Array($0) })
        data.append(rawType)
        data.append(payload)
        return data
    }

    // MARK: - Convenience

    /// Creates a wire-format failure response (no payload).
    static func failureResponse() -> Data {
        SSHAgentMessage(type: .failure, payload: Data()).serialize()
    }

    /// Parses an identities-answer payload into an array of identities.
    /// Payload format: [4-byte nkeys] then for each key: [4-byte blob length] [blob] [4-byte comment length] [comment].
    func parseIdentities() throws -> [SSHAgentIdentity] {
        guard type == .identitiesAnswer else {
            throw SSHAgentError.unexpectedMessageType
        }
        guard payload.count >= 4 else {
            throw SSHAgentError.messageTooShort
        }

        let nkeys = payload.readUInt32(at: 0)
        var offset = 4
        var identities: [SSHAgentIdentity] = []
        identities.reserveCapacity(Int(nkeys))

        for _ in 0..<nkeys {
            // Read key blob
            guard offset + 4 <= payload.count else { throw SSHAgentError.messageTooShort }
            let blobLength = Int(payload.readUInt32(at: offset))
            offset += 4
            guard offset + blobLength <= payload.count else { throw SSHAgentError.messageTooShort }
            let keyBlob = payload.subdata(in: offset..<(offset + blobLength))
            offset += blobLength

            // Read comment
            guard offset + 4 <= payload.count else { throw SSHAgentError.messageTooShort }
            let commentLength = Int(payload.readUInt32(at: offset))
            offset += 4
            guard offset + commentLength <= payload.count else { throw SSHAgentError.messageTooShort }
            let commentData = payload.subdata(in: offset..<(offset + commentLength))
            offset += commentLength

            let comment = String(data: commentData, encoding: .utf8) ?? ""
            identities.append(SSHAgentIdentity(keyBlob: keyBlob, comment: comment))
        }

        return identities
    }
}

// MARK: - Data Extension

nonisolated extension Data {
    /// Reads a big-endian UInt32 at the given byte offset.
    func readUInt32(at offset: Int) -> UInt32 {
        let bytes = self.subdata(in: offset..<(offset + 4))
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}

// MARK: - FileHandle Extension

nonisolated extension FileHandle {
    /// Reads exactly `count` bytes, throwing `unexpectedEOF` if the stream ends early.
    /// Uses POSIX read() instead of NSFileHandle.readData to avoid ObjC exceptions
    /// when the file descriptor is closed during a blocking read.
    func readExact(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let fd = self.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0

        while totalRead < count {
            let bytesRead = buffer.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress! + totalRead, count - totalRead)
            }
            if bytesRead <= 0 {
                throw SSHAgentError.unexpectedEOF
            }
            totalRead += bytesRead
        }

        return Data(buffer)
    }

    /// Writes data to the file descriptor using POSIX write().
    /// Uses POSIX instead of NSFileHandle.write() to avoid ObjC exceptions
    /// when the file descriptor is closed or the peer disconnects.
    func writeAll(_ data: Data) throws {
        let fd = self.fileDescriptor
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < data.count {
                let bytesWritten = Darwin.write(fd, baseAddress + totalWritten, data.count - totalWritten)
                if bytesWritten <= 0 {
                    throw SSHAgentError.unexpectedEOF
                }
                totalWritten += bytesWritten
            }
        }
    }
}
