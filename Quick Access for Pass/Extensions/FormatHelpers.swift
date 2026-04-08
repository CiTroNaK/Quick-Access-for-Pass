import Foundation

nonisolated enum FormatHelpers {
    static func relativeExpiration(_ date: Date?) -> String {
        guard let date else { return String(localized: "Forever") }
        let remaining = Int(date.timeIntervalSinceNow)
        if remaining < 60 { return String(localized: "expires in \(max(remaining, 0))s") }
        if remaining < 3600 { return String(localized: "expires in \(remaining / 60)m") }
        if remaining < 86400 {
            // time unit abbreviations
            // swiftlint:disable identifier_name
            let h = remaining / 3600
            let m = (remaining % 3600) / 60
            // swiftlint:enable identifier_name
            return m > 0 ? String(localized: "expires in \(h)h \(m)m") : String(localized: "expires in \(h)h")
        }
        return String(localized: "expires in \(remaining / 86400)d")
    }

    static func formatSyncTime(_ timestamp: Double, relativeTo now: Date) -> String {
        guard timestamp > 0 else { return String(localized: "Never") }
        let date = Date(timeIntervalSince1970: timestamp)
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 10 { return String(localized: "just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
