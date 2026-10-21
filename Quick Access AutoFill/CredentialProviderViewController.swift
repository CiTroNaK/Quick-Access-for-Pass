import AppKit
import AuthenticationServices
import Foundation
import os
import SwiftUI

@MainActor
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var requestTask: Task<Void, Never>?
    private var pickerLoadTask: Task<Void, Never>?
    private var requestToken: UUID?
    private var pickerModel: AutoFillCandidatePickerModel?
    private var hostedView: NSView?
    private lazy var systemProvider = SystemCredentialProvider(context: extensionContext)
    private lazy var requestGate = AutoFillCredentialRequestGate(provider: systemProvider)

    override func loadView() {
        // Authentication Services invokes one of the request callbacks before
        // visible content is needed. Keeping this root inert prevents an
        // unrelated controller instance from presenting an empty picker canvas.
        view = NSView(frame: .zero)
    }


    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        installPicker(services: serviceIdentifiers, kind: .password)
    }

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        installPicker(services: serviceIdentifiers, kind: .password)
    }

    override func prepareOneTimeCodeCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier]
    ) {
        installPicker(services: serviceIdentifiers, kind: .oneTimeCode)
    }

    override func provideCredentialWithoutUserInteraction(
        for credentialRequest: any ASCredentialRequest
    ) {
        // Authentication Services does not permit broker I/O or UI on this path.
        // It will invoke the interactive callback below after this cancellation.
        AutoFillCredentialRequestPolicy.requireUserInteraction(using: systemProvider)
    }

    override func prepareInterfaceToProvideCredential(
        for credentialRequest: any ASCredentialRequest
    ) {
        showResolvingView()
        provide(credentialRequest)
    }

    deinit {
        requestTask?.cancel()
        pickerLoadTask?.cancel()
    }

    @objc private func cancelInteractiveRequest() {
        pickerLoadTask?.cancel()
        pickerLoadTask = nil
        pickerModel?.cancel()
        requestTask?.cancel()
        guard let requestToken else { return }
        requestGate.provider(for: requestToken).cancelRequest(with: .userCanceled)
        finishRequest(token: requestToken)
    }

    private func showResolvingView() {
        pickerLoadTask?.cancel()
        pickerLoadTask = nil
        pickerModel?.cancel()
        pickerModel = nil
        installResolvingView()
    }

    /// Replaces the picker host after it has already begun the one active
    /// resolution request. It must not cancel the picker model's task.
    private func showPickerResolvingView() {
        pickerLoadTask?.cancel()
        pickerLoadTask = nil
        installResolvingView()
    }

    private func installResolvingView() {
        hostedView?.removeFromSuperview()

        let resolvingView = NSHostingView(rootView: AutoFillResolvingView(onCancel: { [weak self] in
            self?.cancelInteractiveRequest()
        })
        .fixedSize())
        resolvingView.translatesAutoresizingMaskIntoConstraints = false
        resolvingView.layoutSubtreeIfNeeded()
        AutoFillCandidatePickerPresentation.applyContentSize(
            AutoFillCandidatePickerPresentation.resolvingPresentationSize(
                for: resolvingView.fittingSize
            ),
            to: self
        )

        view.addSubview(resolvingView)
        NSLayoutConstraint.activate([
            resolvingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            resolvingView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        hostedView = resolvingView
    }

    private func provide(_ request: any ASCredentialRequest) {
        pickerLoadTask?.cancel()
        pickerLoadTask = nil
        pickerModel?.cancel()
        pickerModel = nil
        let supersededTask = requestTask
        let token = requestGate.beginRequest()
        let provider = requestGate.provider(for: token)
        requestToken = token
        supersededTask?.cancel()
        guard let coordinator = makeCoordinator(provider: provider) else {
            provider.cancelRequest(with: .failed)
            finishRequest(token: token)
            return
        }

        if let passwordRequest = request as? ASPasswordCredentialRequest,
           let identity = passwordRequest.credentialIdentity as? ASPasswordCredentialIdentity {
            requestTask = Task { [self] in
                await coordinator.providePassword(
                    recordIdentifier: identity.recordIdentifier,
                    username: identity.user
                )
                finishRequest(token: token)
            }
            return
        }

        if let codeRequest = request as? ASOneTimeCodeCredentialRequest,
           let identity = codeRequest.credentialIdentity as? ASOneTimeCodeCredentialIdentity {
            requestTask = Task { [self] in
                await coordinator.provideOneTimeCode(
                    recordIdentifier: identity.recordIdentifier
                )
                finishRequest(token: token)
            }
            return
        }

        // This provider intentionally has no passkey identity or completion path.
        provider.cancelRequest(with: .failed)
        finishRequest(token: token)
    }

    private func finishRequest(token: UUID) {
        guard requestToken == token else { return }
        requestGate.finishRequest(token)
        requestTask = nil
        requestToken = nil
    }

    private func installPicker(
        services: [ASCredentialServiceIdentifier],
        kind: AutoFillValueKind,
        startsLoading: Bool = true
    ) {
        AutoFillCandidatePickerPresentation.applyContentSize(
            AutoFillCandidatePickerPresentation.pickerContentSize,
            to: self
        )
        pickerLoadTask?.cancel()
        pickerLoadTask = nil
        pickerModel?.cancel()
        requestTask?.cancel()
        hostedView?.removeFromSuperview()

        let provider: any CredentialProviding
        if startsLoading {
            let token = requestGate.beginRequest()
            requestToken = token
            provider = requestGate.provider(for: token)
        } else {
            provider = systemProvider
        }

        let model = makePickerModel(provider: provider) ?? AutoFillCandidatePickerModel(
            lister: UnavailableCandidatePickerLister(),
            completion: UnavailableCandidatePickerCompletion()
        )

        pickerModel = model
        let picker = AutoFillCandidatePickerView(
            model: model,
            onCancel: { [weak self] in
                self?.cancelInteractiveRequest()
            },
            onResolving: { [weak self] in
                self?.showPickerResolvingView()
            },
            onContentSizeChange: { [weak self] size in
                guard let self else { return }
                AutoFillCandidatePickerPresentation.applyContentSize(size, to: self)
            }
        )
        let hostingView = NSHostingView(rootView: picker)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostedView = hostingView

        guard startsLoading else { return }
        let convertedServices = services.compactMap(\.autoFillServiceIdentifier)
        pickerLoadTask = Task { @MainActor [weak self, weak model] in
            guard Task.isCancelled == false,
                  let self,
                  let model,
                  self.pickerModel === model else { return }
            await model.load(services: convertedServices, kind: kind)
        }
    }

    private func makePickerModel(
        provider: any CredentialProviding
    ) -> AutoFillCandidatePickerModel? {
        guard let client = try? AutoFillBrokerClient(
            hostOpener: WorkspaceAutoFillHostOpener()
        ) else {
            return nil
        }
        let coordinator = AutoFillExtensionCoordinator(resolver: client, provider: provider)
        return AutoFillCandidatePickerModel(lister: client, completion: coordinator)
    }

    private func makeCoordinator(
        provider: any CredentialProviding
    ) -> AutoFillExtensionCoordinator? {
        guard let client = try? AutoFillBrokerClient(
            hostOpener: WorkspaceAutoFillHostOpener()
        ) else {
            return nil
        }
        return AutoFillExtensionCoordinator(resolver: client, provider: provider)
    }
}

nonisolated private enum UnavailableCandidatePickerError: Error {
    case unavailable
}

nonisolated private struct UnavailableCandidatePickerLister: AutoFillBrokerListing {
    func listCandidates(
        _ query: AutoFillCandidateQuery,
        deadline: UInt64
    ) async throws -> [AutoFillCandidate] {
        throw UnavailableCandidatePickerError.unavailable
    }
}

@MainActor
private final class UnavailableCandidatePickerCompletion: AutoFillCandidatePickerCompleting {
    func provide(
        candidate: AutoFillCandidate,
        appAssociationIntent: AutoFillAppAssociationIntent?
    ) async {}
}

private extension ASCredentialServiceIdentifier {
    var autoFillServiceIdentifier: AutoFillServiceIdentifier? {
        let kind: AutoFillServiceIdentifierKind
        switch type {
        case .domain:
            kind = .domain
        case .URL:
            kind = .url
        case .app:
            kind = .app
        @unknown default:
            return nil
        }
        return try? AutoFillServiceIdentifier(kind: kind, identifier: identifier, displayName: nil)
    }
}

@MainActor
private final class SystemCredentialProvider: CredentialProviding {
    private let context: ASCredentialProviderExtensionContext

    init(context: ASCredentialProviderExtensionContext) {
        self.context = context
    }

    func completePassword(user: String, password: String) async throws {
        let credential = ASPasswordCredential(user: user, password: password)
        try await waitForSystemCompletion { completion in
            context.completeRequest(
                withSelectedCredential: credential,
                completionHandler: completion
            )
        }
    }

    func completeOneTimeCode(_ code: String) async throws {
        let credential = ASOneTimeCodeCredential(code: code)
        try await waitForSystemCompletion { completion in
            context.completeOneTimeCodeRequest(
                using: credential,
                completionHandler: completion
            )
        }
    }

    func cancelRequest(with error: AutoFillCredentialProviderError) {
        let code: ASExtensionError.Code = switch error {
        case .userCanceled: .userCanceled
        case .userInteractionRequired: .userInteractionRequired
        case .credentialIdentityNotFound: .credentialIdentityNotFound
        case .failed: .failed
        }
        context.cancelRequest(
            withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue)
        )
    }

    private func waitForSystemCompletion(
        _ operation: (@escaping @Sendable (Bool) -> Void) -> Void
    ) async throws {
        let gate = SystemCompletionGate()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                _ = gate.install(continuation)
                // Once the token gate chooses completion as the terminal result,
                // always submit it even if cancellation wins this callback wait.
                operation { _ in gate.finish(.completed) }
            }
        } onCancel: {
            gate.finish(.cancelled)
        }

        if outcome == .cancelled { throw CancellationError() }
    }
}

nonisolated private enum SystemCompletionOutcome: Equatable, Sendable {
    case completed
    case cancelled
}

nonisolated private final class SystemCompletionGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<SystemCompletionOutcome, Never>?
        var outcome: SystemCompletionOutcome?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(
        _ continuation: CheckedContinuation<SystemCompletionOutcome, Never>
    ) -> Bool {
        let outcome = state.withLock { state -> SystemCompletionOutcome? in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        guard let outcome else { return true }
        continuation.resume(returning: outcome)
        return false
    }

    func finish(_ outcome: SystemCompletionOutcome) {
        let continuation = state.withLock { state -> CheckedContinuation<SystemCompletionOutcome, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }
}
