import Foundation

/// Preserves the original live deadline; cache-first requests need no fallback reserve.
nonisolated enum OfflineAutoFillLiveBudget {
    static func deadline(
        context: SecretResolutionContext,
        now: UInt64
    ) throws -> CLIExecutionDeadline? {
        guard let requestDeadline = context.deadlineUptimeNanoseconds else { return nil }
        guard requestDeadline > now else { throw SecretResolutionError.deadlineExpired }
        return CLIExecutionDeadline(uptimeNanoseconds: requestDeadline)
    }

    static func timeout(
        context: SecretResolutionContext,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> TimeInterval? {
        guard let deadline = context.deadlineUptimeNanoseconds else { return nil }
        guard deadline > now else { throw SecretResolutionError.deadlineExpired }
        return Double(deadline - now) / 1_000_000_000
    }
}
