import Foundation

nonisolated enum LockoutTimeout: Double, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case fourHours = 14_400
    case eightHours = 28_800
    case twelveHours = 43_200
    case oneDay = 86_400

    static let `default`: LockoutTimeout = .oneHour

    var id: Double { rawValue }
    var seconds: TimeInterval { rawValue }

    var localizedLabel: String {
        switch self {
        case .fiveMinutes: String(localized: "\(5) minutes")
        case .tenMinutes: String(localized: "\(10) minutes")
        case .fifteenMinutes: String(localized: "\(15) minutes")
        case .thirtyMinutes: String(localized: "\(30) minutes")
        case .oneHour: String(localized: "\(1) hours")
        case .twoHours: String(localized: "\(2) hours")
        case .fourHours: String(localized: "\(4) hours")
        case .eightHours: String(localized: "\(8) hours")
        case .twelveHours: String(localized: "\(12) hours")
        case .oneDay: String(localized: "\(1) days")
        }
    }
}
