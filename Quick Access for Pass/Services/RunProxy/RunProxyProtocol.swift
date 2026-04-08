import Foundation

/// JSON request from qa-run → RunProxy.
/// Wire format: [4-byte big-endian length] [JSON payload]
nonisolated struct RunProxyRequest: Codable, Sendable {
    let profile: String
    let command: [String]
    let pid: Int32
}

/// JSON response from RunProxy → qa-run.
nonisolated enum RunProxyDecision: String, Codable, Sendable {
    case allow
    case deny
}

nonisolated struct RunProxyResponse: Codable, Sendable {
    let decision: RunProxyDecision
    /// Resolved environment variables to inject (key=value). Only set on allow.
    let env: [String: String]?
}

/// Read/write helpers for length-prefixed JSON over a file descriptor.
nonisolated enum RunProxyWire {

    /// Read a length-prefixed JSON message from a FileHandle.
    /// Format: [4-byte big-endian UInt32 length] [JSON bytes]
    static func readMessage<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T {
        let lengthData = try handle.readExact(count: 4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0 && length < 1_000_000 else {
            throw RunProxyError.invalidMessage
        }
        let jsonData = try handle.readExact(count: Int(length))
        return try JSONDecoder().decode(T.self, from: jsonData)
    }

    /// Write a length-prefixed JSON message to a FileHandle.
    static func writeMessage<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let jsonData = try JSONEncoder().encode(value)
        var length = UInt32(jsonData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        try handle.writeAll(lengthData)
        try handle.writeAll(jsonData)
    }
}

nonisolated enum RunProxyError: Error, LocalizedError {
    case connectionClosed
    case invalidMessage
    case unknownProfile(String)

    var errorDescription: String? {
        switch self {
        case .connectionClosed: String(localized: "Connection closed")
        case .invalidMessage: String(localized: "Invalid message")
        case .unknownProfile(let slug): String(localized: "Unknown profile: \(slug)")
        }
    }
}

/// Constants for RunProxyProbe health checks.
///
/// `reservedPingSlug` is a sentinel profile slug used exclusively by
/// RunProxyProbe for round-trip health pings. RunProxy.handleClient
/// fast-paths requests carrying this slug and replies with an allow
/// response without invoking the auth handler or writing any DB rows.
/// The slug is rejected by profile save validation so no user profile
/// can collide with it.
nonisolated enum RunProxyProbeConstants {
    static let reservedPingSlug = "__qa_ping__"
}
