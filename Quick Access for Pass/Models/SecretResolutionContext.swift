import Foundation

/// Immutable broker policy carried through live and offline secret resolution.
nonisolated struct SecretResolutionContext: Sendable {
    let deadlineUptimeNanoseconds: UInt64?
    let expectedUsername: String?

    static let ordinary = Self(deadlineUptimeNanoseconds: nil, expectedUsername: nil)
}

nonisolated enum SecretResolutionError: Error, Sendable {
    case deadlineExpired
}
