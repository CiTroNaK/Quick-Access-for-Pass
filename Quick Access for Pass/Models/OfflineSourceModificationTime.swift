import Foundation

/// Parses upstream source markers without manufacturing a successful version on failure.
nonisolated enum OfflineSourceModificationTime {
    /// Accepts explicit ISO 8601 offsets and the CLI's server-derived UTC civil form.
    static func parse(_ rawValue: String) -> Date? {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?$"#
        guard rawValue.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let hasOffset = rawValue.hasSuffix("Z") || rawValue.dropFirst(19).contains("+") || rawValue.dropFirst(19).contains("-")
        let normalized = hasOffset ? rawValue : rawValue + "Z"
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: rawValue.contains("."))
        return try? format.parse(normalized)
    }
}
