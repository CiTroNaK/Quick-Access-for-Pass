import Foundation

/// Failures signalled out of SSHAgentProxy.runClientLoop back to the coordinator.
/// Symmetric with RunClientLoopFailure for the Run proxy side.
nonisolated enum SSHClientLoopFailure: Sendable, Equatable {
    case upstreamConnectFailed(errno: Int32)
    case upstreamWriteFailed
    case upstreamResponseReadFailed
}
