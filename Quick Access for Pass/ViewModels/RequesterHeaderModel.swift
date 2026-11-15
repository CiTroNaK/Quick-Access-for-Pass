import AppKit
import Foundation
import Observation

/// Request-scoped display context. It never supplies authorization identity or scope.
@MainActor @Observable final class RequesterHeaderModel {
    private(set) var presentation: RequesterPresentation
    private(set) var detailsEligible = false
    /// Herdr.app icon resolved once on the main actor when a Core lookup publishes it.
    private(set) var overrideIconImage: NSImage?
    private let clientInfo: SSHClientInfo
    private let snapshot: RequesterProcessSnapshot?
    private let store: TerminalHostStore
    private let detailsProvider: any HerdrPaneDetailsProviding
    private let coreDetailsProvider: any HerdrCoreTerminalDetailsProviding
    /// Herdr Core is recognized by signature, not configured, so store changes never affect this branch.
    private let coreMatch: HerdrCoreTerminalMatch?
    /// nil where no settings are composed (tests and previews): Core context is then on.
    private let coreSettings: HerdrCoreSettings?
    @ObservationIgnored private var operation: Task<HerdrPaneDetails?, Never>?
    @ObservationIgnored private var coreOperation: Task<HerdrCoreLookup?, Never>?
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var coreSubscription: UUID?
    private var matchingEntries: [TerminalHostMatchingEntry]
    private var availableIDs: Set<String>
    private var hostMatch: TerminalHostMatch?
    private var generation: UInt64 = 0
    private var attempted = false
    private var cancelled = false

    init(clientInfo: SSHClientInfo, snapshot: RequesterProcessSnapshot?, store: TerminalHostStore,
         detailsProvider: any HerdrPaneDetailsProviding, coreDetailsProvider: any HerdrCoreTerminalDetailsProviding,
         coreSettings: HerdrCoreSettings? = nil) {
        self.clientInfo = clientInfo
        self.snapshot = snapshot
        self.store = store
        self.detailsProvider = detailsProvider
        self.coreDetailsProvider = coreDetailsProvider
        self.coreSettings = coreSettings
        coreMatch = HerdrCoreTerminalResolver.match(clientInfo: clientInfo, snapshot: snapshot)
        // Discovery belongs to the store and occurs only for actually displayed requests; Core never uses the store.
        if coreMatch == nil, let snapshot {
            for node in [snapshot.requester] + snapshot.ancestors.prefix(10) {
                store.observeExecutable(at: URL(fileURLWithPath: node.executablePath))
            }
        }
        let entries = store.matchingEntries
        matchingEntries = entries
        availableIDs = store.availableIDs
        let resolved = RequesterPresentationResolver.resolve(clientInfo: clientInfo, snapshot: snapshot, entries: entries)
        presentation = resolved.presentation
        hostMatch = resolved.hostMatch
        let entry = entries.first { $0.configuration.id == resolved.hostMatch?.configurationID }?.configuration
        detailsEligible = coreMatch != nil ? isCoreEnabled : (entry?.provider == .herdr && entry?.showPaneDetails == true)
        if coreMatch == nil {
            subscription = store.observeChanges { [weak self] in self?.refreshConfiguration() }
        } else {
            coreSubscription = coreSettings?.observeChanges { [weak self] in self?.refreshCoreSettings() }
        }
    }

    private var isCoreEnabled: Bool { coreSettings?.isEnabled ?? true }
    private var showsCoreDetails: Bool { coreSettings?.showsDetails ?? true }

    /// Like `refreshConfiguration` for Herdr: a switch turned off clears what it controls. Turning Core off also
    /// cancels the lookup; turning details off lets it finish for the icon and drops its details on arrival.
    private func refreshCoreSettings() {
        guard !cancelled, coreMatch != nil else { return }
        detailsEligible = isCoreEnabled
        if !showsCoreDetails || !isCoreEnabled { presentation = presentation.replacing(details: nil) }
        guard !isCoreEnabled else { return }
        generation &+= 1
        coreOperation?.cancel()
        coreOperation = nil
        presentation = presentation.replacing(iconOverride: nil)
        overrideIconImage = nil
    }

    func refreshConfiguration() {
        guard !cancelled, coreMatch == nil,
              matchingEntries != store.matchingEntries || availableIDs != store.availableIDs else { return }
        matchingEntries = store.matchingEntries
        availableIDs = store.availableIDs
        generation &+= 1
        operation?.cancel()
        operation = nil
        let resolved = RequesterPresentationResolver.resolve(clientInfo: clientInfo, snapshot: snapshot, entries: matchingEntries)
        presentation = resolved.presentation
        hostMatch = resolved.hostMatch
        let entry = matchingEntries.first { $0.configuration.id == hostMatch?.configurationID }?.configuration
        detailsEligible = entry?.provider == .herdr && entry?.showPaneDetails == true
    }

    func loadDetails() async {
        if let coreMatch {
            await loadCoreDetails(coreMatch)
            return
        }
        guard !cancelled, !Task.isCancelled, !attempted, detailsEligible, let hostMatch else { return }
        attempted = true
        let currentGeneration = generation
        let provider = detailsProvider
        let task = Task { await provider.details(for: hostMatch) }
        operation = task
        let details = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !cancelled, generation == currentGeneration else { return }
        operation = nil
        guard !Task.isCancelled, !task.isCancelled else { return }
        presentation = presentation.replacing(details: details)
    }

    private func loadCoreDetails(_ match: HerdrCoreTerminalMatch) async {
        guard !cancelled, !Task.isCancelled, !attempted, isCoreEnabled else { return }
        attempted = true
        let currentGeneration = generation
        let provider = coreDetailsProvider
        let includeDetails = showsCoreDetails
        let task = Task { await provider.lookup(match, includeDetails: includeDetails) }
        coreOperation = task
        let lookup = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !cancelled, generation == currentGeneration else { return }
        coreOperation = nil
        guard !Task.isCancelled, !task.isCancelled, let lookup else { return }
        let icon: RequesterIcon = lookup.herdrAppURL.map { .bundle($0) } ?? .symbol("terminal")
        if case .bundle(let url) = icon { overrideIconImage = NSWorkspace.shared.icon(forFile: url.path) }
        presentation = presentation.replacing(iconOverride: icon).replacing(details: showsCoreDetails ? lookup.details : nil)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        generation &+= 1
        operation?.cancel()
        operation = nil
        coreOperation?.cancel()
        coreOperation = nil
        if let subscription { store.removeObserver(subscription) }
        subscription = nil
        if let coreSubscription { coreSettings?.removeObserver(coreSubscription) }
        coreSubscription = nil
        presentation = presentation.replacing(details: nil)
    }
}
