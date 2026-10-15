import Foundation

/// Invocation-bound evidence for the supported complete snapshot representation.
nonisolated enum CLISnapshotContentProvenance: Sendable, Equatable {
    case unavailable
    case completeJSONV1

    /// Completeness additionally requires all modeled fields, not decoder defaults.
    static func validatesShape(_ raw: Any, of item: CLIItem) -> Bool {
        guard let encoded = try? JSONEncoder().encode(item),
              let expected = try? JSONSerialization.jsonObject(with: encoded) else { return false }
        return containsShape(raw, expected: expected)
    }

    private static func containsShape(_ raw: Any, expected: Any) -> Bool {
        if let object = expected as? [String: Any] {
            guard let source = raw as? [String: Any] else { return false }
            return object.allSatisfy { key, value in
                guard let received = source[key] else { return false }
                return containsShape(received, expected: value)
            }
        }
        if let values = expected as? [Any] {
            guard let source = raw as? [Any], source.count == values.count else { return false }
            return zip(source, values).allSatisfy { containsShape($0, expected: $1) }
        }
        if expected is NSNull { return raw is NSNull }
        if expected is String { return raw is String }
        if expected is NSNumber { return raw is NSNumber }
        return false
    }
}
