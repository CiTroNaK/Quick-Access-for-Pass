import Foundation

nonisolated enum SyncDiagnosticFileStore {
    static let largeReportThreshold = 50

    static func writeSkippedItems(
        _ skippedItems: [SkippedSyncItem],
        date: Date = Date(),
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard skippedItems.count > largeReportThreshold else { return nil }
        let directory = try diagnosticsDirectory(baseDirectory: baseDirectory, fileManager: fileManager)
        let filename = "sync-skipped-items-\(timestampString(from: date)).txt"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let body = skippedItems.map(\.diagnosticSummary).joined(separator: "\n")
        try SyncErrorDiagnosticReport.sanitize(body).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func diagnosticsDirectory(baseDirectory: URL?, fileManager: FileManager) throws -> URL {
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            root = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let directory = root.appendingPathComponent("SyncDiagnostics", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
