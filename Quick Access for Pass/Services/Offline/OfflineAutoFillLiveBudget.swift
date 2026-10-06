import Foundation

/// Computes the live attempt budget without reading persistence or clock state.
nonisolated enum OfflineAutoFillLiveBudget {
    static func timeout(
        context: SecretResolutionContext,
        hasSnapshot: Bool,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> TimeInterval? {
        guard let deadline = context.deadlineUptimeNanoseconds else { return nil }
        guard deadline > now else { throw SecretResolutionError.deadlineExpired }
        let remaining = Double(deadline - now) / 1_000_000_000
        guard hasSnapshot else { return remaining }
        let live = min(2, remaining - 1)
        guard live > 0 else { throw SecretResolutionError.deadlineExpired }
        return live
    }
}
