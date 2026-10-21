import Darwin
import Foundation

/// Indicates that credential frame bytes reached the peer but the complete frame
/// could not be delivered. The accepted-connection owner must close the socket;
/// callers must not append a failure frame to this partial credential stream.
nonisolated enum AutoFillWireDeliveryError: Error, Equatable, Sendable {
    case partialFrame
}

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

    /// Bounded fail-closed credential delivery used only inside the MainActor
    /// final release turn. The connection owner must already have transitioned
    /// its socket to O_NONBLOCK: Darwin AF_UNIX sends can block despite
    /// MSG_DONTWAIT on a blocking descriptor. This helper neither changes flags
    /// nor closes its borrowed descriptor. A partial frame gets no later frame.
    static func writeMessageNonblocking<T: AutoFillWireMessage>(
        _ message: T,
        toFileDescriptor fd: Int32
    ) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, flags & O_NONBLOCK != 0 else {
            throw AutoFillProtocolError.connectionClosed
        }
        let payload = try encodeMessage(message)
        guard payload.isEmpty == false, payload.count <= maximumMessageSize else {
            throw AutoFillProtocolError.messageTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        try frame.withUnsafeBytes { try writeAllNonblocking($0, to: fd) }
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

    private static func writeAllNonblocking(_ buffer: UnsafeRawBufferPointer, to fd: Int32) throws {
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        var interrupted = 0
        while offset < buffer.count {
            let result = Darwin.send(fd, baseAddress.advanced(by: offset), buffer.count - offset, MSG_DONTWAIT | MSG_NOSIGNAL)
            if result > 0 {
                offset += result
                continue
            }
            if result < 0, errno == EINTR, interrupted < 8 {
                interrupted += 1
                continue
            }
            // A partial credential frame cannot be followed by an error frame.
            // The accepted-connection task remains the sole descriptor owner and
            // closes it in its defer after processor cleanup completes.
            if offset > 0 { throw AutoFillWireDeliveryError.partialFrame }
            throw AutoFillProtocolError.connectionClosed
        }
    }
}
