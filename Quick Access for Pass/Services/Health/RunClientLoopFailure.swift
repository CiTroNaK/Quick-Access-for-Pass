import Foundation

/// Failures signalled out of RunProxy.handleClient back to the coordinator.
/// Mirrors SSHClientLoopFailure for the SSH side; cases use the `client*`
/// prefix since the Run proxy has no upstream — failures are client-facing.
nonisolated enum RunClientLoopFailure: Sendable, Equatable {
    case clientRequestReadFailed
    case authHandlerTimedOut
    case clientResponseWriteFailed
}
