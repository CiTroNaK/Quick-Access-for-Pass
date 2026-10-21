import Foundation
import Observation

/// Extension-only completion boundary; implementations resolve only the selected opaque descriptor.
@MainActor
protocol AutoFillCandidatePickerCompleting: AnyObject, Sendable {
    func provide(
        candidate: AutoFillCandidate,
        appAssociationIntent: AutoFillAppAssociationIntent?
    ) async
}

@MainActor
@Observable
final class AutoFillCandidatePickerModel {
    enum State: Equatable {
        case waitingForRequest
        case loading
        case siteResults([AutoFillCandidate])
        case searchResults([AutoFillCandidate])
        case empty
        case unavailable
        case resolving
    }

    private static let requestLifetimeNanoseconds: UInt64 = 30_000_000_000

    private let lister: any AutoFillBrokerListing
    private let completion: any AutoFillCandidatePickerCompleting
    private let now: @Sendable () -> UInt64
    private let searchDebounce: Duration

    private(set) var state: State = .waitingForRequest
    private(set) var selectedCandidateID: UUID?
    var searchQuery = ""

    var canRememberForApp: Bool {
        services.contains { $0.kind == .app }
    }
    private var services: [AutoFillServiceIdentifier] = []
    private var kind: AutoFillValueKind?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(
        lister: any AutoFillBrokerListing,
        completion: any AutoFillCandidatePickerCompleting,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        searchDebounce: Duration = .milliseconds(250)
    ) {
        self.lister = lister
        self.completion = completion
        self.now = now
        self.searchDebounce = searchDebounce
    }

    isolated deinit {
        task?.cancel()
    }

    func load(services: [AutoFillServiceIdentifier], kind: AutoFillValueKind) async {
        self.services = services
        self.kind = kind
        searchQuery = ""
        startSiteRequest()
        await task?.value
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        guard kind != nil else { return }

        if let normalized = AutoFillCandidateQuery.normalizedSearch(query) {
            startGlobalSearch(normalized)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startSiteRequest()
        }
    }

    func moveSelection(by offset: Int) {
        let candidates = displayedCandidates
        guard candidates.isEmpty == false else {
            selectedCandidateID = nil
            return
        }
        let currentIndex = candidates.firstIndex { $0.descriptorID == selectedCandidateID } ?? 0
        selectedCandidateID = candidates[max(0, min(currentIndex + offset, candidates.count - 1))].descriptorID
    }

    func selectActiveCandidate(rememberForApp: Bool) async {
        guard let candidate = displayedCandidates.first(where: { $0.descriptorID == selectedCandidateID }) else {
            return
        }
        await select(candidate, rememberForApp: rememberForApp)
    }

    func select(_ candidate: AutoFillCandidate, rememberForApp: Bool) async {
        guard displayedCandidates.contains(candidate), candidate.kind == kind else { return }
        selectedCandidateID = candidate.descriptorID
        replaceTask()
        let token = generation
        state = .resolving
        let associationIntent = associationIntent(rememberForApp: rememberForApp)
        let completion = completion
        task = Task { @MainActor [weak self] in
            await completion.provide(
                candidate: candidate,
                appAssociationIntent: associationIntent
            )
            guard let self, Task.isCancelled == false, generation == token else { return }
        }
        await task?.value
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = UUID()
        state = .waitingForRequest
        selectedCandidateID = nil
    }

    private var displayedCandidates: [AutoFillCandidate] {
        switch state {
        case .siteResults(let candidates), .searchResults(let candidates): candidates
        default: []
        }
    }

    private func startSiteRequest() {
        guard let kind else {
            state = .waitingForRequest
            return
        }
        // Some native fields provide no usable service context. Keep global
        // search available without encoding an invalid empty site request.
        guard services.isEmpty == false else {
            replaceTask()
            state = .empty
            selectedCandidateID = nil
            return
        }
        startList(.site(
            requestID: UUID(),
            services: services,
            kind: kind,
            deadlineUptimeNanoseconds: requestDeadline()
        ), isSearch: false)
    }

    private func startGlobalSearch(_ search: String) {
        guard let kind else { return }
        startList(.global(
            requestID: UUID(),
            search: search,
            kind: kind,
            deadlineUptimeNanoseconds: requestDeadline()
        ), isSearch: true)
    }

    private func startList(_ query: AutoFillCandidateQuery, isSearch: Bool) {
        replaceTask()
        let token = generation
        state = .loading
        let lister = lister
        let debounce = searchDebounce
        task = Task { @MainActor [weak self] in
            do {
                if isSearch, debounce > .zero {
                    try await Task.sleep(for: debounce)
                }
                try Task.checkCancellation()
                let candidates = try await lister.listCandidates(
                    query,
                    deadline: query.deadlineUptimeNanoseconds
                )
                guard let self, Task.isCancelled == false, generation == token else { return }
                guard candidates.count <= AutoFillCandidate.maximumCandidates else {
                    state = .unavailable
                    return
                }
                if candidates.isEmpty {
                    state = .empty
                    selectedCandidateID = nil
                } else {
                    state = isSearch ? .searchResults(candidates) : .siteResults(candidates)
                    if isSearch {
                        selectedCandidateID = candidates.first?.descriptorID
                    } else {
                        retainOrSelectFirstCandidate(in: candidates)
                    }
                }
            } catch is CancellationError {
                // Replaced and explicitly cancelled requests leave presentation state unchanged.
            } catch {
                guard let self, Task.isCancelled == false, generation == token else { return }
                state = .unavailable
            }
        }
    }

    private func retainOrSelectFirstCandidate(in candidates: [AutoFillCandidate]) {
        guard candidates.contains(where: { $0.descriptorID == selectedCandidateID }) else {
            selectedCandidateID = candidates.first?.descriptorID
            return
        }
    }

    private func replaceTask() {
        task?.cancel()
        task = nil
        generation = UUID()
    }

    private func associationIntent(rememberForApp: Bool) -> AutoFillAppAssociationIntent? {
        guard rememberForApp,
              let service = services.first(where: { $0.kind == .app }) else {
            return nil
        }
        return try? AutoFillAppAssociationIntent(service: service)
    }

    private func requestDeadline() -> UInt64 {
        let (deadline, overflow) = now().addingReportingOverflow(Self.requestLifetimeNanoseconds)
        return overflow ? UInt64.max : deadline
    }
}
