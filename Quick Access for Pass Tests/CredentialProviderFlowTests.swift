import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("Credential provider password and one-time-code flow")
struct CredentialProviderFlowTests {
    @Test("selected password identity resolves and completes exactly once")
    @MainActor
    func passwordCompletion() async throws {
        let descriptorID = UUID()
        let resolver = FakeCredentialResolver(result: .success("fake-password"))
        let provider = FakeCredentialProvider()
        let coordinator = AutoFillExtensionCoordinator(resolver: resolver, provider: provider)

        await coordinator.providePassword(
            recordIdentifier: descriptorID.uuidString,
            username: "person@example.com"
        )

        #expect(provider.events() == [
            .password(user: "person@example.com", value: "fake-password")
        ])
        let request = try #require(resolver.requests().first)
        #expect(request.descriptorID == descriptorID)
        #expect(request.kind == .password)
        #expect(request.appAssociationIntent == nil)
    }

    @Test("selected one-time-code identity resolves and completes exactly once")
    @MainActor
    func oneTimeCodeCompletion() async {
        let resolver = FakeCredentialResolver(result: .success("654321"))
        let provider = FakeCredentialProvider()
        let coordinator = AutoFillExtensionCoordinator(resolver: resolver, provider: provider)

        await coordinator.provideOneTimeCode(recordIdentifier: UUID().uuidString)

        #expect(provider.events() == [.oneTimeCode(value: "654321")])
        #expect(resolver.requests().map(\.kind) == [.oneTimeCode])
    }

    @Test("a no-interaction request asks the system to present the interactive flow without resolving a secret")
    @MainActor
    func noInteractionRequestRequiresUserInteraction() {
        let resolver = FakeCredentialResolver(result: .success("unused"))
        let provider = FakeCredentialProvider()
        _ = AutoFillExtensionCoordinator(resolver: resolver, provider: provider)

        AutoFillCredentialRequestPolicy.requireUserInteraction(using: provider)

        #expect(provider.events() == [.failure(.userInteractionRequired)])
        #expect(resolver.requests().isEmpty)
    }

    @Test("multiple available identities are not preselected or resolved by the coordinator")
    @MainActor
    func multipleMatchesRemainSystemOwned() async {
        let resolver = FakeCredentialResolver(result: .success("unused"))
        let provider = FakeCredentialProvider()
        let coordinator = AutoFillExtensionCoordinator(resolver: resolver, provider: provider)

        coordinator.prepareCredentialListForSystemPicker()
        coordinator.prepareOneTimeCodeCredentialListForSystemPicker()
        try? await Task.sleep(for: .milliseconds(10))

        #expect(resolver.requests().isEmpty)
        #expect(provider.events().isEmpty)
    }

    @Test("malformed and stale identities fail without fallback search")
    @MainActor
    func invalidIdentityAndStaleDescriptor() async {
        let malformedResolver = FakeCredentialResolver(result: .success("unused"))
        let malformedProvider = FakeCredentialProvider()
        let malformed = AutoFillExtensionCoordinator(
            resolver: malformedResolver,
            provider: malformedProvider
        )

        await malformed.providePassword(recordIdentifier: "not-a-uuid", username: "person")

        #expect(malformedResolver.requests().isEmpty)
        #expect(malformedProvider.events() == [.failure(.credentialIdentityNotFound)])

        let staleResolver = FakeCredentialResolver(
            result: .failure(AutoFillBrokerClientError.brokerFailure(.resolutionFailed))
        )
        let staleProvider = FakeCredentialProvider()
        let stale = AutoFillExtensionCoordinator(resolver: staleResolver, provider: staleProvider)

        await stale.providePassword(recordIdentifier: UUID().uuidString, username: "person")

        #expect(staleResolver.requests().count == 1)
        #expect(staleProvider.events() == [.failure(.credentialIdentityNotFound)])
    }

    @Test("cancellation terminates the request and completes the system failure once")
    @MainActor
    func cancellationCompletesOnce() async throws {
        let resolver = FakeCredentialResolver(blockUntilCancelled: true)
        let provider = FakeCredentialProvider()
        let coordinator = AutoFillExtensionCoordinator(resolver: resolver, provider: provider)
        let task = Task {
            await coordinator.providePassword(
                recordIdentifier: UUID().uuidString,
                username: "person"
            )
        }
        #expect(await waitUntil { resolver.requests().count == 1 })

        task.cancel()
        await task.value

        #expect(provider.events() == [.failure(.userCanceled)])
        #expect(resolver.cancellationCount() == 1)
    }

    @Test("superseded request cannot complete or cancel the replacement context")
    @MainActor
    func supersededRequestIsTokenScoped() async throws {
        let systemProvider = FakeCredentialProvider()
        let gate = AutoFillCredentialRequestGate(provider: systemProvider)
        let oldResolver = FakeCredentialResolver(blockUntilCancelled: true)
        let oldToken = gate.beginRequest()
        let oldProvider = gate.provider(for: oldToken)
        let oldCoordinator = AutoFillExtensionCoordinator(
            resolver: oldResolver,
            provider: oldProvider
        )
        let oldTask = Task {
            await oldCoordinator.providePassword(
                recordIdentifier: UUID().uuidString,
                username: "old-user"
            )
        }
        #expect(await waitUntil { oldResolver.requests().count == 1 })

        let newToken = gate.beginRequest()
        let newProvider = gate.provider(for: newToken)
        oldTask.cancel()
        let newCoordinator = AutoFillExtensionCoordinator(
            resolver: FakeCredentialResolver(result: .success("new-password")),
            provider: newProvider
        )
        await newCoordinator.providePassword(
            recordIdentifier: UUID().uuidString,
            username: "new-user"
        )
        await oldTask.value

        #expect(oldResolver.cancellationCount() == 1)
        #expect(systemProvider.events() == [
            .password(user: "new-user", value: "new-password")
        ])

        await oldCoordinator.providePassword(recordIdentifier: "invalid", username: "old-user")
        oldProvider.cancelRequest(with: .failed)
        #expect(systemProvider.events().count == 1)
    }

    @Test("cancellation while system completion is pending returns without a second terminal call")
    @MainActor
    func cancellationDrainsSystemCompletion() async throws {
        let resolver = FakeCredentialResolver(result: .success("fake-password"))
        let provider = FakeCredentialProvider(suspendCompletion: true)
        let coordinator = AutoFillExtensionCoordinator(resolver: resolver, provider: provider)
        let task = Task {
            await coordinator.providePassword(
                recordIdentifier: UUID().uuidString,
                username: "person"
            )
        }
        #expect(await waitUntil { provider.hasPendingSystemCompletion() })

        task.cancel()
        await task.value

        #expect(provider.events() == [.password(user: "person", value: "fake-password")])
        #expect(provider.completionCancellationCount == 1)
        provider.finishSystemCompletion()
        #expect(provider.ignoredSystemCompletionCount == 1)
    }

    @Test("provider completion callback keeps the async flow alive")
    @MainActor
    func waitsForSystemCompletion() async throws {
        let resolver = FakeCredentialResolver(result: .success("fake-password"))
        let provider = FakeCredentialProvider(suspendCompletion: true)
        let coordinator = AutoFillExtensionCoordinator(resolver: resolver, provider: provider)
        let task = Task {
            await coordinator.providePassword(
                recordIdentifier: UUID().uuidString,
                username: "person"
            )
        }
        #expect(await waitUntil { provider.events().count == 1 })
        #expect(task.isCancelled == false)
        #expect(provider.hasPendingSystemCompletion())

        provider.finishSystemCompletion()
        await task.value

        #expect(provider.events().count == 1)
    }

    @Test("the extension flow exposes only password and one-time-code value kinds")
    func noPasskeyPath() {
        #expect(AutoFillValueKind(rawValue: "password") == .password)
        #expect(AutoFillValueKind(rawValue: "oneTimeCode") == .oneTimeCode)
        #expect(AutoFillValueKind(rawValue: "passkey") == nil)
    }

    @Test("resolving presentation fits content and picker presentation retains its size")
    @MainActor
    func presentationSizes() {
        #expect(
            AutoFillCandidatePickerPresentation.resolvingPresentationSize(
                for: CGSize(width: 236, height: 20)
            ) == CGSize(width: 260, height: 44)
        )
        #expect(AutoFillCandidatePickerPresentation.pickerContentSize == CGSize(width: 360, height: 420))
    }

    @Test("replacing a picker cancels its queued load before stale broker I/O")
    func pickerReplacementCancelsQueuedLoad() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/CredentialProviderViewController.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("private var pickerLoadTask: Task<Void, Never>?"))
        #expect(source.contains("pickerLoadTask?.cancel()"))
        #expect(source.contains("deinit {\n        requestTask?.cancel()\n        pickerLoadTask?.cancel()"))
        #expect(source.contains("guard Task.isCancelled == false,"))
        #expect(source.contains("self.pickerModel === model else { return }"))
    }

    @Test("visible picker content is mounted only by Authentication Services callbacks")
    func presentationDoesNotMountFallbackContentDuringViewLifecycle() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/CredentialProviderViewController.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("override func viewWillAppear()") == false)
        #expect(source.contains("didInstallWaitingPicker") == false)
        #expect(source.contains("installPicker(services: [], kind: .password, startsLoading: false)") == false)
        #expect(source.contains("override func prepareCredentialList(") )
        #expect(source.contains("override func prepareInterfaceToProvideCredential("))
    }

    @Test("credential provider covers every interactive list callback")
    func pickerCallbackCoverage() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/CredentialProviderViewController.swift"
            ),
            encoding: .utf8
        )

        for requiredSnippet in [
            "override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier])",
            "requestParameters: ASPasskeyCredentialRequestParameters",
            "override func prepareOneTimeCodeCredentialList(",
            "installPicker(services: serviceIdentifiers, kind: .password)",
            "installPicker(services: serviceIdentifiers, kind: .oneTimeCode)"
        ] {
            #expect(source.contains(requiredSnippet), "Missing callback routing: \(requiredSnippet)")
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private struct CredentialResolutionRequest: Sendable {
    let descriptorID: UUID
    let kind: AutoFillValueKind
    let deadline: UInt64
    let appAssociationIntent: AutoFillAppAssociationIntent?
}

private final class FakeCredentialResolver: AutoFillBrokerResolving, Sendable {
    private struct State {
        var requests: [CredentialResolutionRequest] = []
        var cancellationCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let result: Result<String, any Error>?
    private let blockUntilCancelled: Bool

    init(result: Result<String, any Error>) {
        self.result = result
        blockUntilCancelled = false
    }

    init(blockUntilCancelled: Bool) {
        result = nil
        self.blockUntilCancelled = blockUntilCancelled
    }

    func resolve(
        descriptorID: UUID,
        kind: AutoFillValueKind,
        deadline: UInt64,
        appAssociationIntent: AutoFillAppAssociationIntent?
    ) async throws -> String {
        state.withLock {
            $0.requests.append(.init(
                descriptorID: descriptorID,
                kind: kind,
                deadline: deadline,
                appAssociationIntent: appAssociationIntent
            ))
        }
        if blockUntilCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                state.withLock { $0.cancellationCount += 1 }
                throw error
            }
            return "unexpected"
        }
        return try result!.get()
    }

    func requests() -> [CredentialResolutionRequest] { state.withLock(\.requests) }
    func cancellationCount() -> Int { state.withLock(\.cancellationCount) }
}

@MainActor
private final class FakeCredentialProvider: CredentialProviding {
    enum Event: Equatable {
        case password(user: String, value: String)
        case oneTimeCode(value: String)
        case failure(AutoFillCredentialProviderError)
    }

    private var recordedEvents: [Event] = []
    private let suspendCompletion: Bool
    private var completionContinuation: CheckedContinuation<Void, any Error>?
    private(set) var completionCancellationCount = 0
    private(set) var ignoredSystemCompletionCount = 0

    init(suspendCompletion: Bool = false) {
        self.suspendCompletion = suspendCompletion
    }

    func completePassword(user: String, password: String) async throws {
        recordedEvents.append(.password(user: user, value: password))
        try await waitForSystemCompletionIfNeeded()
    }

    func completeOneTimeCode(_ code: String) async throws {
        recordedEvents.append(.oneTimeCode(value: code))
        try await waitForSystemCompletionIfNeeded()
    }

    func cancelRequest(with error: AutoFillCredentialProviderError) {
        recordedEvents.append(.failure(error))
    }

    func events() -> [Event] { recordedEvents }
    func hasPendingSystemCompletion() -> Bool { completionContinuation != nil }

    func finishSystemCompletion() {
        guard let completionContinuation else {
            ignoredSystemCompletionCount += 1
            return
        }
        self.completionContinuation = nil
        completionContinuation.resume()
    }

    private func waitForSystemCompletionIfNeeded() async throws {
        guard suspendCompletion else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completionContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in self.cancelSystemCompletion() }
        }
    }

    private func cancelSystemCompletion() {
        guard let completionContinuation else { return }
        self.completionContinuation = nil
        completionCancellationCount += 1
        completionContinuation.resume(throwing: CancellationError())
    }
}
