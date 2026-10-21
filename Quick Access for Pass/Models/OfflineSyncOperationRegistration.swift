import Foundation

/// Service lifecycle bookkeeping only. Plaintext, prepared output and secret-bearing closures
/// stay in the caller's joined frame, never this registry.
nonisolated struct OfflineSyncOperationRegistration: Sendable {
    let id: UUID
    let lifecycleGeneration: UUID
    var capture: OfflineSyncCapture?
    var isConsuming = false
}
