import Foundation

/// Non-queuing ownership of explicit CLI authentication and compound settings mutations.
@MainActor
final class PassCLISessionMutationGate {
    nonisolated enum Operation: Sendable {
        case browserLogin
        case savedTokenLogin
        case logout
    }

    /// An operation-scoped, non-secret identity; never persisted or logged.
    nonisolated struct Lease: Sendable, Equatable {
        fileprivate let id: UUID
        let operation: Operation
    }

    nonisolated enum AdmissionError: Error, LocalizedError {
        case busy

        var errorDescription: String? { String(localized: "Sign-in already in progress.") }
    }

    private var activeLease: Lease?

    /// Whether another operation owns admission, including cancellation unwind.
    var isBusy: Bool { activeLease != nil }

    /// Claims ownership immediately, or declines without queuing.
    func tryAcquire(_ operation: Operation) -> Lease? {
        guard activeLease == nil else { return nil }
        let lease = Lease(id: UUID(), operation: operation)
        activeLease = lease
        return lease
    }

    /// Checks that an operation still owns this specific gate.
    func owns(_ lease: Lease) -> Bool { activeLease == lease }

    /// Releases only the matching owner; a stale release cannot unlock a newer operation.
    func release(_ lease: Lease) {
        guard owns(lease) else { return }
        activeLease = nil
    }
}
