import Foundation

nonisolated struct SyncSkippedItemsPresentation: Equatable, Sendable {
    static let visibleItemLimit = 20

    let skippedItems: [SkippedSyncItem]
    let diagnosticFileURL: URL?
    let diagnosticReport: String

    var visibleItems: [SkippedSyncItem] {
        Array(skippedItems.prefix(Self.visibleItemLimit))
    }

    var visibleSummaries: [String] {
        visibleItems.map { SyncErrorDiagnosticReport.sanitize($0.diagnosticSummary) }
    }

    var hiddenItemCount: Int {
        max(0, skippedItems.count - Self.visibleItemLimit)
    }

    static func make(
        skippedItems: [SkippedSyncItem],
        diagnosticFileURL: URL?,
        date: Date = Date()
    ) -> SyncSkippedItemsPresentation? {
        guard !skippedItems.isEmpty else { return nil }
        return SyncSkippedItemsPresentation(
            skippedItems: skippedItems,
            diagnosticFileURL: diagnosticFileURL,
            diagnosticReport: makeReport(
                skippedItems: skippedItems,
                diagnosticFileURL: diagnosticFileURL,
                date: date
            )
        )
    }

    private static func makeReport(
        skippedItems: [SkippedSyncItem],
        diagnosticFileURL: URL?,
        date: Date
    ) -> String {
        let timestamp = timestampString(from: date)
        let summaries = skippedItems.map(\.diagnosticSummary).joined(separator: "\n")
        let fileLine = diagnosticFileURL.map { "\nFull skipped-item diagnostics file: \($0.path)" } ?? ""

        return SyncErrorDiagnosticReport.sanitize(
            """
            Quick Access for Pass Skipped Sync Items Report

            Review this report for anything sensitive before sending it.

            Timestamp: \(timestamp)
            Skipped items: \(skippedItems.count)
            \(fileLine)

            Skipped item summaries:
            \(summaries)
            """
        )
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
