import Foundation
import Observation

/// Request-scoped display context. It never supplies authorization identity or scope.
@MainActor @Observable final class RequesterHeaderModel {
    private(set) var presentation: RequesterPresentation
    private(set) var detailsEligible = false
    private let clientInfo: SSHClientInfo
    private let snapshot: RequesterProcessSnapshot?
    private let store: TerminalHostStore
    private let detailsProvider: any HerdrPaneDetailsProviding
    @ObservationIgnored private var operation: Task<HerdrPaneDetails?, Never>?
    @ObservationIgnored private var subscription: UUID?
    private var matchingEntries: [TerminalHostMatchingEntry]
    private var availableIDs: Set<String>
    private var hostMatch: TerminalHostMatch?
    private var generation: UInt64 = 0
    private var attempted = false
    private var cancelled = false

    init(clientInfo: SSHClientInfo, snapshot: RequesterProcessSnapshot?, store: TerminalHostStore,
         detailsProvider: any HerdrPaneDetailsProviding) {
        self.clientInfo = clientInfo
        self.snapshot = snapshot
        self.store = store
        self.detailsProvider = detailsProvider
        // Discovery belongs to the store and occurs only for actually displayed requests.
        if let snapshot {
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
        detailsEligible = entry?.provider == .herdr && entry?.showPaneDetails == true
        subscription = store.observeChanges { [weak self] in self?.refreshConfiguration() }
    }

    func refreshConfiguration() {
        guard !cancelled, matchingEntries != store.matchingEntries || availableIDs != store.availableIDs else { return }
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
        presentation = .init(name: presentation.name, bundleURL: presentation.bundleURL,
                             symbolName: presentation.symbolName, hostID: presentation.hostID, details: details)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        generation &+= 1
        operation?.cancel()
        operation = nil
        if let subscription { store.removeObserver(subscription) }
        subscription = nil
        presentation = .init(name: presentation.name, bundleURL: presentation.bundleURL,
                             symbolName: presentation.symbolName, hostID: presentation.hostID, details: nil)
    }
}
