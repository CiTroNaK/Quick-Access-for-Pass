import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill candidate picker model", .serialized)
struct AutoFillCandidatePickerModelTests {
    @Test("missing service context waits for search without issuing an invalid site query", arguments: [AutoFillValueKind.password, .oneTimeCode])
    @MainActor
    func missingServiceContextWaitsForSearch(kind: AutoFillValueKind) async throws {
        let result = candidate(kind: kind, tier: 0)
        let broker = FakePickerBroker(globalResult: [result])
        let model = AutoFillCandidatePickerModel(
            lister: broker,
            completion: FakePickerGateway(),
            searchDebounce: .zero
        )

        await model.load(services: [], kind: kind)

        #expect(model.state == .empty)
        #expect(model.selectedCandidateID == nil)
        #expect(model.canRememberForApp == false)
        #expect(broker.queries().isEmpty)

        model.updateSearchQuery("credential")
        #expect(await eventually { model.state == .searchResults([result]) })
        #expect(model.selectedCandidateID == result.descriptorID)

        model.updateSearchQuery("")
        #expect(await eventually { model.state == .empty })
        #expect(model.selectedCandidateID == nil)
        #expect(broker.queries().count == 1)
    }

    @Test("removing service context cancels older search publication")
    @MainActor
    func missingContextInvalidatesOldSearch() async throws {
        let website = try service(.domain, "example.com")
        let broker = FakePickerBroker(delayedSearches: true)
        let model = AutoFillCandidatePickerModel(
            lister: broker, completion: FakePickerGateway(), searchDebounce: .zero
        )
        await model.load(services: [website], kind: .password)
        model.updateSearchQuery("old")
        #expect(await eventually { broker.queries().count == 2 })

        await model.load(services: [], kind: .password)
        broker.finishSearch(named: "old", with: [candidate(kind: .password, tier: 0)])
        // A new search supplies a deterministic publication barrier for the replaced task.
        model.updateSearchQuery("new")
        #expect(await eventually { broker.queries().contains {
            if case .global(_, "new", _, _, _) = $0 { return true }
            return false
        } })
        broker.finishSearch(named: "new", with: [])
        #expect(await eventually { model.state == .empty })
        #expect(broker.queries().count == 3)
        #expect(model.selectedCandidateID == nil)
    }

    @Test("loads site candidates in supplied service order")
    @MainActor
    func loadsSiteCandidates() async throws {
        let subdomain = try service(.domain, "login.example.com")
        let parentDomain = try service(.domain, "example.com")
        let subdomainCandidate = candidate(kind: .password, tier: 0)
        let parentCandidate = candidate(kind: .password, tier: 1)
        let broker = FakePickerBroker(siteResult: [subdomainCandidate, parentCandidate])
        let gateway = FakePickerGateway()
        let model = AutoFillCandidatePickerModel(lister: broker, completion: gateway)

        await model.load(services: [subdomain, parentDomain], kind: .password)

        #expect(model.state == .siteResults([subdomainCandidate, parentCandidate]))
    }

    @Test("a typed query replaces site results with global candidates")
    @MainActor
    func typedSearchLoadsGlobalCandidates() async throws {
        let service = try service(.domain, "example.com")
        let globalCandidate = candidate(kind: .password, tier: 0)
        let broker = FakePickerBroker(globalResult: [globalCandidate])
        let gateway = FakePickerGateway()
        let model = AutoFillCandidatePickerModel(
            lister: broker,
            completion: gateway,
            searchDebounce: .zero
        )
        await model.load(services: [service], kind: .password)

        model.updateSearchQuery("git")
        #expect(await eventually { model.state == .searchResults([globalCandidate]) })
        #expect(broker.queries().contains { query in
            if case .global(_, let search, _, _, _) = query { return search == "git" }
            return false
        })
    }

    @Test("an older delayed query cannot overwrite a newer query")
    @MainActor
    func staleSearchCannotOverwriteNewerSearch() async throws {
        let service = try service(.domain, "example.com")
        let oldCandidate = candidate(kind: .password, tier: 0)
        let newCandidate = candidate(kind: .password, tier: 0)
        let broker = FakePickerBroker(delayedSearches: true)
        let gateway = FakePickerGateway()
        let model = AutoFillCandidatePickerModel(
            lister: broker,
            completion: gateway,
            searchDebounce: .zero
        )
        await model.load(services: [service], kind: .password)

        model.updateSearchQuery("old")
        #expect(await eventually { broker.queries().count == 2 })
        model.updateSearchQuery("new")
        #expect(await eventually { broker.queries().count == 3 })
        broker.finishSearch(named: "new", with: [newCandidate])
        #expect(await eventually { model.state == .searchResults([newCandidate]) })
        broker.finishSearch(named: "old", with: [oldCandidate])
        try? await Task.sleep(for: .milliseconds(10))

        #expect(model.state == .searchResults([newCandidate]))
    }

    @Test("cancelling a list request does not create an unavailable state")
    @MainActor
    func cancellationDoesNotBecomeAnError() async throws {
        let service = try service(.domain, "example.com")
        let broker = FakePickerBroker(delayedSearches: true)
        let gateway = FakePickerGateway()
        let model = AutoFillCandidatePickerModel(lister: broker, completion: gateway)
        let task = Task { await model.load(services: [service], kind: .password) }
        #expect(await eventually { broker.queries().count == 1 })

        model.cancel()
        await task.value

        #expect(model.state == .waitingForRequest)
    }

    @Test("selection resolves only the selected opaque descriptor")
    @MainActor
    func selectionResolvesSelectedDescriptor() async throws {
        let service = try service(.domain, "example.com")
        let selected = candidate(kind: .password, tier: 0)
        let unselected = candidate(kind: .password, tier: 0)
        let broker = FakePickerBroker(siteResult: [selected, unselected])
        let gateway = FakePickerGateway()
        let model = AutoFillCandidatePickerModel(lister: broker, completion: gateway)
        await model.load(services: [service], kind: .password)

        await model.select(selected, rememberForApp: false)

        #expect(gateway.requests.map(\.candidate.descriptorID) == [selected.descriptorID])
        #expect(gateway.requests.map(\.candidate) == [selected])
    }

    @Test("first loaded candidate is selected and navigation stays bounded")
    @MainActor
    func defaultsAndNavigatesSelection() async throws {
        let service = try service(.domain, "example.com")
        let first = candidate(kind: .password, tier: 0)
        let second = candidate(kind: .password, tier: 1)
        let broker = FakePickerBroker(siteResult: [first, second])
        let model = AutoFillCandidatePickerModel(lister: broker, completion: FakePickerGateway())

        await model.load(services: [service], kind: .password)

        #expect(model.selectedCandidateID == first.descriptorID)
        model.moveSelection(by: 1)
        #expect(model.selectedCandidateID == second.descriptorID)
        model.moveSelection(by: 1)
        #expect(model.selectedCandidateID == second.descriptorID)
        model.moveSelection(by: -1)
        #expect(model.selectedCandidateID == first.descriptorID)
    }

    @Test("global search always selects its first result")
    @MainActor
    func globalSearchResetsSelectionToFirstResult() async throws {
        let service = try service(.domain, "example.com")
        let first = candidate(kind: .password, tier: 0)
        let second = candidate(kind: .password, tier: 0)
        let broker = FakePickerBroker(siteResult: [first, second], globalResult: [first, second])
        let model = AutoFillCandidatePickerModel(
            lister: broker,
            completion: FakePickerGateway(),
            searchDebounce: .zero
        )

        await model.load(services: [service], kind: .password)
        model.moveSelection(by: 1)
        model.updateSearchQuery("credential")

        #expect(await eventually { model.state == .searchResults([first, second]) })
        #expect(model.selectedCandidateID == first.descriptorID)
    }

    @Test("site results retain a visible selection")
    @MainActor
    func siteResultsRetainVisibleSelection() async throws {
        let service = try service(.domain, "example.com")
        let first = candidate(kind: .password, tier: 0)
        let second = candidate(kind: .password, tier: 0)
        let model = AutoFillCandidatePickerModel(
            lister: FakePickerBroker(siteResult: [first, second]),
            completion: FakePickerGateway()
        )

        await model.load(services: [service], kind: .password)
        model.moveSelection(by: 1)
        await model.load(services: [service], kind: .password)

        #expect(model.state == .siteResults([first, second]))
        #expect(model.selectedCandidateID == second.descriptorID)
    }

    @Test("selecting the active candidate resolves only its descriptor")
    @MainActor
    func selectsActiveCandidate() async throws {
        let service = try service(.domain, "example.com")
        let first = candidate(kind: .password, tier: 0)
        let second = candidate(kind: .password, tier: 0)
        let gateway = FakePickerGateway()
        let model = AutoFillCandidatePickerModel(
            lister: FakePickerBroker(siteResult: [first, second]),
            completion: gateway
        )

        await model.load(services: [service], kind: .password)
        model.moveSelection(by: 1)
        await model.selectActiveCandidate(rememberForApp: false)

        #expect(gateway.requests.map(\.candidate.descriptorID) == [second.descriptorID])
    }

    @Test("app association intent requires a typed app service and explicit choice")
    @MainActor
    func appAssociationIntentIsExplicit() async throws {
        let app = try service(.app, "com.example.app")
        let website = try service(.domain, "example.com")
        let selected = candidate(kind: .password, tier: 0)
        let appBroker = FakePickerBroker(siteResult: [selected])
        let appGateway = FakePickerGateway()
        let appModel = AutoFillCandidatePickerModel(lister: appBroker, completion: appGateway)
        await appModel.load(services: [app], kind: .password)
        await appModel.select(selected, rememberForApp: true)
        #expect(appGateway.requests.first?.appAssociationIntent?.service == app)

        let webBroker = FakePickerBroker(siteResult: [selected])
        let webGateway = FakePickerGateway()
        let webModel = AutoFillCandidatePickerModel(lister: webBroker, completion: webGateway)
        await webModel.load(services: [website], kind: .password)
        await webModel.select(selected, rememberForApp: true)
        #expect(webGateway.requests.first?.appAssociationIntent == nil)
    }

    private func service(
        _ kind: AutoFillServiceIdentifierKind,
        _ identifier: String
    ) throws -> AutoFillServiceIdentifier {
        try AutoFillServiceIdentifier(kind: kind, identifier: identifier, displayName: nil)
    }

    private func candidate(kind: AutoFillValueKind, tier: Int) -> AutoFillCandidate {
        AutoFillCandidate(
            descriptorID: UUID(),
            title: "Test credential",
            username: "person@example.com",
            kind: kind,
            matchTier: tier
        )
    }

    @MainActor
    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private final class FakePickerBroker: AutoFillBrokerListing, Sendable {
    private struct State {
        var queries: [AutoFillCandidateQuery] = []
        var searchContinuations: [String: CheckedContinuation<[AutoFillCandidate], any Error>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let siteResult: [AutoFillCandidate]
    private let globalResult: [AutoFillCandidate]
    private let delayedSearches: Bool

    init(
        siteResult: [AutoFillCandidate] = [],
        globalResult: [AutoFillCandidate] = [],
        delayedSearches: Bool = false
    ) {
        self.siteResult = siteResult
        self.globalResult = globalResult
        self.delayedSearches = delayedSearches
    }

    func listCandidates(_ query: AutoFillCandidateQuery, deadline: UInt64) async throws -> [AutoFillCandidate] {
        state.withLock { $0.queries.append(query) }
        if case .global(_, let search, _, _, _) = query, delayedSearches {
            return try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.searchContinuations[search] = continuation }
            }
        }
        if case .site = query { return siteResult }
        return globalResult
    }


    func queries() -> [AutoFillCandidateQuery] { state.withLock(\.queries) }

    func finishSearch(named search: String, with candidates: [AutoFillCandidate]) {
        let continuation = state.withLock { $0.searchContinuations.removeValue(forKey: search) }
        continuation?.resume(returning: candidates)
    }
}

@MainActor
private final class FakePickerGateway: AutoFillCandidatePickerCompleting {
    struct Request: Equatable {
        let candidate: AutoFillCandidate
        let appAssociationIntent: AutoFillAppAssociationIntent?
    }

    private(set) var requests: [Request] = []

    func provide(
        candidate: AutoFillCandidate,
        appAssociationIntent: AutoFillAppAssociationIntent?
    ) async {
        requests.append(.init(candidate: candidate, appAssociationIntent: appAssociationIntent))
    }
}
