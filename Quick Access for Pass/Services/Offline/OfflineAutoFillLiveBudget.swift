import Foundation

/// Computes the live attempt budget without reading persistence or clock state.
nonisolated enum OfflineAutoFillLiveBudget {
    static func deadline(
        context: SecretResolutionContext,
        hasSnapshot: Bool,
        now: UInt64
    ) throws -> CLIExecutionDeadline? {
        guard let requestDeadline = context.deadlineUptimeNanoseconds else { return nil }
        guard requestDeadline > now else { throw SecretResolutionError.deadlineExpired }
        guard hasSnapshot else { return CLIExecutionDeadline(uptimeNanoseconds: requestDeadline) }

        let reserve: UInt64 = 1_000_000_000
        guard requestDeadline - now > reserve else { throw SecretResolutionError.deadlineExpired }
        let cappedLiveDeadline = now.addingReportingOverflow(2_000_000_000)
        let liveDeadline = cappedLiveDeadline.overflow ? UInt64.max : cappedLiveDeadline.partialValue
        return CLIExecutionDeadline(uptimeNanoseconds: min(requestDeadline - reserve, liveDeadline))
    }

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
