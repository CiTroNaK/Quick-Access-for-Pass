import Foundation

nonisolated enum ProxyHealthState: Sendable, Equatable, Hashable {
    case disabled
    case ok(detail: String? = nil)
    case degraded(Reason)
    case unreachable(Reason)

    nonisolated enum Reason: Sendable, Equatable, Hashable, CustomStringConvertible {
        case emptyIdentities
        case probeFailed
        case clientLoopFailure
        case cooldown
        case passCLINotLoggedIn
        case passCLIFailed(String)

        var userFacingText: String {
            switch self {
            case .emptyIdentities:       return String(localized: "no keys available")
            case .probeFailed:           return String(localized: "probe failed")
            case .clientLoopFailure:     return String(localized: "upstream error")
            case .cooldown:              return String(localized: "waiting before retry")
            case .passCLINotLoggedIn:    return String(localized: "pass-cli not logged in")
            case .passCLIFailed:         return String(localized: "pass-cli error")
            }
        }
        var description: String { userFacingText }

        /// Hand-rolled case list for parameterized tests. Not `CaseIterable`
        /// because `.passCLIFailed` carries an associated value.
        static let allKnown: [Reason] = [
            .emptyIdentities,
            .probeFailed,
            .clientLoopFailure,
            .cooldown,
            .passCLINotLoggedIn,
            .passCLIFailed("test reason"),
        ]
    }

    nonisolated enum Severity: Int, Sendable, Comparable {
        case nominal = 0
        case degraded = 1
        case unreachable = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var severity: Severity {
        switch self {
        case .ok, .disabled: return .nominal
        case .degraded:      return .degraded
        case .unreachable:   return .unreachable
        }
    }
}
