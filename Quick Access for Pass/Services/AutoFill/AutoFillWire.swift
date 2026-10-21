import Darwin
import Foundation

/// Strict length-prefixed JSON framing for the dedicated AutoFill broker.
/// The four-byte big-endian length is validated before allocating the body buffer.
nonisolated enum AutoFillWire {
    static let protocolVersion: UInt16 = 2
    static let maximumMessageSize = 64 * 1024

    static func readMessage<T: AutoFillWireMessage>(
        _ type: T.Type,
        fromFileDescriptor fd: Int32
    ) throws -> T {
        let header = try readExactly(count: MemoryLayout<UInt32>.size, from: fd)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumMessageSize) else {
            throw AutoFillProtocolError.invalidLength
        }
        let payload = try readExactly(count: Int(length), from: fd)
        return try decodeMessage(type, from: Data(payload))
    }

    static func writeMessage<T: AutoFillWireMessage>(
        _ message: T,
        toFileDescriptor fd: Int32
    ) throws {
        let payload = try encodeMessage(message)
        guard payload.isEmpty == false, payload.count <= maximumMessageSize else {
            throw AutoFillProtocolError.messageTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: fd) }
        try payload.withUnsafeBytes { try writeAll($0, to: fd) }
    }

    static func encodeMessage<T: AutoFillWireMessage>(_ message: T) throws -> Data {
        do {
            let data = try JSONEncoder().encode(message)
            guard data.isEmpty == false else { throw AutoFillProtocolError.malformedMessage }
            return data
        } catch let error as AutoFillProtocolError {
            throw error
        } catch {
            throw AutoFillProtocolError.malformedMessage
        }
    }

    static func decodeMessage<T: AutoFillWireMessage>(
        _ type: T.Type,
        from payload: Data
    ) throws -> T {
        guard payload.isEmpty == false, payload.count <= maximumMessageSize else {
            throw payload.isEmpty
                ? AutoFillProtocolError.invalidLength
                : AutoFillProtocolError.messageTooLarge
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  T.validateJSONKeys(Set(object.keys), in: object) else {
                throw AutoFillProtocolError.malformedMessage
            }
            return try JSONDecoder().decode(type, from: payload)
        } catch let error as AutoFillProtocolError {
            throw error
        } catch {
            throw AutoFillProtocolError.malformedMessage
        }
    }

    static func decodeResponse(
        _ type: AutoFillBrokerResponse.Type,
        from payload: Data,
        matching requestID: UUID
    ) throws -> AutoFillBrokerResponse {
        let response = try decodeMessage(type, from: payload)
        guard response.requestID == requestID else {
            throw AutoFillProtocolError.malformedMessage
        }
        return response
    }

    private static func readExactly(count: Int, from fd: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if result > 0 {
                offset += result
            } else if result == 0 {
                throw AutoFillProtocolError.connectionClosed
            } else if errno != EINTR {
                throw AutoFillProtocolError.connectionClosed
            }
        }
        return bytes
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: Int32) throws {
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let result = Darwin.write(fd, baseAddress.advanced(by: offset), buffer.count - offset)
            if result > 0 {
                offset += result
            } else if result == 0 {
                throw AutoFillProtocolError.connectionClosed
            } else if errno != EINTR {
                throw AutoFillProtocolError.connectionClosed
            }
        }
    }
}
