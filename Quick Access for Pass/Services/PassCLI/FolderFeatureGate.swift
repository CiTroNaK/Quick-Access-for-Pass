import Foundation
import os

/// Metadata-only admission gate. Selection and probe ownership change under one short lock.
/// The lock never spans SQL, native process work, an await, or observer delivery.
nonisolated final class FolderFeatureGate: Sendable {
    private struct State {
        var selection: PassCLISelection
        var selectionGeneration = UUID()
        var probeRevision = UUID()
        var availability: FolderFeatureAvailability = .checking
        var capabilities: PassCLICapabilities?
        /// Executable identity the confirmed capabilities were observed for.
        var probedFingerprint: PassCLIExecutableFingerprint?
        var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(selection: PassCLISelection) {
        state = OSAllocatedUnfairLock(initialState: State(selection: selection))
    }

    var selection: PassCLISelection { state.withLock { $0.selection } }
    var selectionGeneration: UUID { state.withLock { $0.selectionGeneration } }

    /// Captures executable and generation in one read, without a selection/epoch race.
    func selectionSnapshot() -> (selection: PassCLISelection, generation: UUID) {
        state.withLock { ($0.selection, $0.selectionGeneration) }
    }
    var availability: FolderFeatureAvailability { state.withLock { $0.availability } }

    /// Replaces selection and invalidates its evidence atomically, including A→B→A changes.
    @discardableResult
    func updateSelection(_ selection: PassCLISelection) -> Bool {
        let observers = state.withLock { value -> [AsyncStream<Void>.Continuation]? in
            guard value.selection != selection else { return nil }
            value.selection = selection
            Self.invalidate(&value)
            return Array(value.observers.values)
        }
        guard let observers else { return false }
        for observer in observers { observer.yield(()) }
        return true
    }

    func invalidateSelection() {
        let observers = state.withLock { value in
            Self.invalidate(&value)
            return Array(value.observers.values)
        }
        for observer in observers { observer.yield(()) }
    }

    private static func invalidate(_ value: inout State) {
        value.selectionGeneration = UUID()
        value.probeRevision = UUID()
        value.capabilities = nil
        value.probedFingerprint = nil
        value.availability = .checking
    }

    /// Starts a superseding probe; even same-path older completions lose ownership.
    func beginProbe(fingerprint: PassCLIExecutableFingerprint? = nil) -> FolderCapabilityProbe {
        let (probe, observers) = state.withLock { value in
            value.probeRevision = UUID()
            value.availability = .checking
            value.capabilities = nil
            value.probedFingerprint = nil
            return (FolderCapabilityProbe(selection: value.selection,
                                          selectionGeneration: value.selectionGeneration,
                                          revision: value.probeRevision, fingerprint: fingerprint),
                    Array(value.observers.values))
        }
        for observer in observers { observer.yield(()) }
        return probe
    }

    /// A non-cacheable result (failed or timed-out probe) publishes `.unavailable` but keeps
    /// capabilities unknown, so the next caller reprobes instead of reusing a negative answer.
    func confirm(capabilities: PassCLICapabilities, for probe: FolderCapabilityProbe, cacheable: Bool = true) {
        let observers = state.withLock { value -> [AsyncStream<Void>.Continuation] in
            guard value.selectionGeneration == probe.selectionGeneration,
                  value.probeRevision == probe.revision else { return [] }
            value.capabilities = cacheable ? capabilities : nil
            value.probedFingerprint = cacheable ? probe.fingerprint : nil
            value.availability = !cacheable || capabilities.version == nil ? .unavailable :
                (capabilities.supportsFolders ? .supported : .requiresUpgrade)
            return Array(value.observers.values)
        }
        for observer in observers { observer.yield(()) }
    }

    func supportedStamp() -> FolderFeatureStamp? {
        state.withLock { value in
            guard value.availability == .supported else { return nil }
            return FolderFeatureStamp(selectionGeneration: value.selectionGeneration, probeRevision: value.probeRevision)
        }
    }

    enum ProbeReuse: Equatable {
        case reprobe
        /// The confirmed probe still applies; carries its stamp only when folders are supported.
        case reuse(FolderFeatureStamp?)
    }

    /// Reuses the confirmed probe when the same selection still resolves to the same file,
    /// so routine syncs keep committed folder evidence current. An uninspectable file reprobes.
    func probeReuse(selectionGeneration: UUID, fingerprint: PassCLIExecutableFingerprint?) -> ProbeReuse {
        state.withLock { value in
            guard let fingerprint, value.selectionGeneration == selectionGeneration,
                  value.capabilities != nil, value.probedFingerprint == fingerprint else { return .reprobe }
            guard value.availability == .supported else { return .reuse(nil) }
            return .reuse(FolderFeatureStamp(selectionGeneration: value.selectionGeneration,
                                             probeRevision: value.probeRevision))
        }
    }

    func isCurrent(_ stamp: FolderFeatureStamp) -> Bool {
        state.withLock { value in
            value.availability == .supported && value.selectionGeneration == stamp.selectionGeneration &&
                value.probeRevision == stamp.probeRevision
        }
    }

    /// Returns reusable generic CLI capabilities only for the exact selected generation.
    func confirmedCapabilities(for selection: PassCLISelection, generation: UUID) -> PassCLICapabilities? {
        state.withLock { value in
            guard value.selection == selection, value.selectionGeneration == generation else { return nil }
            return value.capabilities
        }
    }

    /// Coalesced change signals. Consumers read the latest state, never trust an old event value.
    func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        state.withLock { $0.observers[id] = continuation }
        continuation.yield(())
        return stream
    }
}
