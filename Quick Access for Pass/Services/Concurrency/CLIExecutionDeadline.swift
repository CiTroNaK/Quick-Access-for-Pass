import Foundation

nonisolated struct CLIExecutionDeadline: Sendable, Equatable {
    let uptimeNanoseconds: UInt64

    func remainingSeconds(at now: UInt64) throws -> TimeInterval {
        guard uptimeNanoseconds > now else { throw CLIError.timeout }
        return Double(uptimeNanoseconds - now) / 1_000_000_000
    }
}
