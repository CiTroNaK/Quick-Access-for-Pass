import Foundation

/// Failure-only input type for SSH proxy health mapping so no dead branches
/// exist in the reason mapper. Mirrors `RunFailureInput` on the Run side.
enum SSHFailureInput: Sendable {
    case probeEmptyIdentities
    case probeUnreachable(SSHProbeFailure)
    case clientLoop(SSHClientLoopFailure)

    var healthReason: ProxyHealthState.Reason {
        switch self {
        case .probeEmptyIdentities: return .emptyIdentities
        case .probeUnreachable:     return .probeFailed
        case .clientLoop:           return .clientLoopFailure
        }
    }
}
