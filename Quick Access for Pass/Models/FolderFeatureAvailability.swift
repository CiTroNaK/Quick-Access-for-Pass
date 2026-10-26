import Foundation

/// Presentation of invocation-bound CLI folder capability, never offline release authority.
nonisolated enum FolderFeatureAvailability: Sendable, Equatable {
    case checking
    case requiresUpgrade
    case unavailable
    case supported
}

/// Identity of a supported executable selection and its latest confirmed capability probe.
nonisolated struct FolderFeatureStamp: Sendable, Equatable {
    let selectionGeneration: UUID
    let probeRevision: UUID
}

/// Immutable ownership of a version probe and the executable it must inspect.
nonisolated struct FolderCapabilityProbe: Sendable, Equatable {
    let selection: PassCLISelection
    let selectionGeneration: UUID
    let revision: UUID
}
