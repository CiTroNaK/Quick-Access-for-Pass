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
    /// Executable identity observed before the probe; nil when it could not be inspected.
    var fingerprint: PassCLIExecutableFingerprint?
}

/// One sync's capability discovery. An inconclusive probe result is reused only within that sync,
/// so it never becomes a cached negative version but also never triggers a second probe.
nonisolated struct PassCLISyncPreparation: Sendable, Equatable {
    var folderFeatureStamp: FolderFeatureStamp?
    var probedSelection: PassCLISelection?
    var probedCapabilities: PassCLICapabilities?

    func capabilities(for selection: PassCLISelection) -> PassCLICapabilities? {
        probedSelection == selection ? probedCapabilities : nil
    }
}
