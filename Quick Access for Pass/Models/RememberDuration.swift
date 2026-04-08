import Foundation

nonisolated enum RememberDuration: String, CaseIterable, Identifiable, Sendable {
    case doNotRemember = "Do not remember"
    case oneMinute = "1 minute"
    case fiveMinutes = "5 minutes"
    case fifteenMinutes = "15 minutes"
    case thirtyMinutes = "30 minutes"
    case oneHour = "1 hour"
    case twoHours = "2 hours"
    case fourHours = "4 hours"
    case oneWeek = "1 week"
    case twoWeeks = "2 weeks"
    case untilEndOfDay = "Until end of day"
    case forever = "Forever"

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .doNotRemember: String(localized: "Do not remember")
        case .oneMinute: String(localized: "\(1) minutes")
        case .fiveMinutes: String(localized: "\(5) minutes")
        case .fifteenMinutes: String(localized: "\(15) minutes")
        case .thirtyMinutes: String(localized: "\(30) minutes")
        case .oneHour: String(localized: "\(1) hours")
        case .twoHours: String(localized: "\(2) hours")
        case .fourHours: String(localized: "\(4) hours")
        case .oneWeek: String(localized: "\(1) weeks")
        case .twoWeeks: String(localized: "\(2) weeks")
        case .untilEndOfDay: String(localized: "Until end of day")
        case .forever: String(localized: "Forever")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func resolved(from now: Date = Date()) -> ResolvedRemember {
        switch self {
        case .doNotRemember:
            return .doNotRemember
        case .oneMinute:       return .expires(now.addingTimeInterval(60))
        case .fiveMinutes:     return .expires(now.addingTimeInterval(300))
        case .fifteenMinutes:  return .expires(now.addingTimeInterval(900))
        case .thirtyMinutes:   return .expires(now.addingTimeInterval(1800))
        case .oneHour:         return .expires(now.addingTimeInterval(3600))
        case .twoHours:        return .expires(now.addingTimeInterval(7200))
        case .fourHours:       return .expires(now.addingTimeInterval(14400))
        case .oneWeek:         return .expires(now.addingTimeInterval(604800))
        case .twoWeeks:        return .expires(now.addingTimeInterval(1209600))
        case .untilEndOfDay:
            let startOfTomorrow = Calendar.current.date(
                byAdding: .day, value: 1,
                to: Calendar.current.startOfDay(for: now)
            ) ?? now.addingTimeInterval(86400)
            return .expires(startOfTomorrow)
        case .forever:
            return .forever
        }
    }
}

nonisolated enum ResolvedRemember: Sendable {
    case doNotRemember
    case expires(Date)
    case forever
}
