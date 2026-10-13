import AppKit
import SwiftUI
import os

@MainActor
final class RunAuthWindowController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<RunAuthDialogView>?
    private var requestQueue: [PendingRunAuthRequest] = []
    private var currentRequest: PendingRunAuthRequest?
    private var isShowingDialog = false
    let databaseManager: DatabaseManager
    private let keychainService: any BiometricAuthorizing
    private let dialogPresenter: (@MainActor @Sendable (RunAuthRequest) -> Void)?
    private let callbacks: AuthDialogHelper.Callbacks
    var sessionCache: [SessionCacheKey: (allowed: Bool, expiresAt: Date)] = [:]
    let sessionCacheDuration: TimeInterval = 10

    /// The independent identity components of a short-lived Run decision.
    nonisolated struct SessionCacheKey: Hashable, Sendable {
        let appIdentifier: String
        let profileSlug: String
        let scope: String
    }

    nonisolated struct AuthorizationMatch: Sendable {
        let scope: String
        let allowed: Bool
    }

    private nonisolated enum DialogOutcome: Sendable {
        case dialog(allowed: Bool, persistedScope: String?)
        case cached(AuthorizationMatch)
    }

    private struct PendingRunAuthRequest {
        let id = UUID()
        let appName: String
        let appBundleURL: URL?
        let profileName: String
        let profileSlug: String
        let scopeOptions: [RunAuthorizationScope]
        let fullCommand: String
        let appIdentifier: String
        let appTeamID: String?
        let continuation: CheckedContinuation<DialogOutcome, Never>
    }

    init(
        databaseManager: DatabaseManager,
        keychainService: any BiometricAuthorizing,
        callbacks: AuthDialogHelper.Callbacks,
        dialogPresenter: (@MainActor @Sendable (RunAuthRequest) -> Void)? = nil
    ) {
        self.databaseManager = databaseManager
        self.keychainService = keychainService
        self.callbacks = callbacks
        self.dialogPresenter = dialogPresenter
    }

    /// Returns whether a cached denial applies without resolving secrets or displaying a prompt.
    func hasCachedDenial(
        for request: RunProxyRequest,
        connection: VerifiedConnection
    ) -> Bool {
        guard let identity = resolveIdentity(for: connection, profile: request.profile) else {
            return true
        }

        let scopeOptions = Self.authorizationScopes(from: request.command)
        guard let match = anyCachedMatch(
            appIdentifier: identity.appIdentifier,
            profileSlug: request.profile,
            scopeOptions: scopeOptions.map(\.key)
        ), match.allowed == false else {
            return false
        }

        logDecision(
            appIdentifier: identity.appIdentifier,
            profile: request.profile,
            command: match.scope,
            allowed: false,
            source: "cached"
        )
        return true
    }

    func authorize(
        request: RunProxyRequest,
        profileName: String,
        env: [String: String],
        connection: VerifiedConnection
    ) async -> RunProxyResponse {
        guard let identity = resolveIdentity(for: connection, profile: request.profile) else {
            return RunProxyResponse(decision: .deny, env: nil)
        }

        let scopeOptions = Self.authorizationScopes(from: request.command)
        if let match = anyCachedMatch(
            appIdentifier: identity.appIdentifier,
            profileSlug: request.profile,
            scopeOptions: scopeOptions.map(\.key)
        ) {
            logDecision(
                appIdentifier: identity.appIdentifier,
                profile: request.profile,
                command: match.scope,
                allowed: match.allowed,
                source: "cached"
            )
            return match.allowed
                ? RunProxyResponse(decision: .allow, env: env)
                : RunProxyResponse(decision: .deny, env: nil)
        }

        let outcome = await enqueueAuthorization(
            identity: identity,
            request: request,
            profileName: profileName,
            scopeOptions: scopeOptions
        )

        switch outcome {
        case .cached(let match):
            return match.allowed
                ? RunProxyResponse(decision: .allow, env: env)
                : RunProxyResponse(decision: .deny, env: nil)
        case .dialog(let allowed, let persistedScope):
            logDecision(
                appIdentifier: identity.appIdentifier,
                profile: request.profile,
                command: persistedScope ?? scopeOptions.first?.key ?? "",
                allowed: allowed,
                source: "dialog"
            )
            return allowed
                ? RunProxyResponse(decision: .allow, env: env)
                : RunProxyResponse(decision: .deny, env: nil)
        }
    }

    func cancelAll() {
        if let current = currentRequest {
            current.continuation.resume(
                returning: .dialog(allowed: false, persistedScope: nil)
            )
            currentRequest = nil
        }
        for pending in requestQueue {
            pending.continuation.resume(
                returning: .dialog(allowed: false, persistedScope: nil)
            )
        }
        requestQueue.removeAll()
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        isShowingDialog = false
    }

    private func persist(
        decisionFor pending: PendingRunAuthRequest,
        resolved: ResolvedRemember,
        scope: String,
        allowed: Bool
    ) {
        let expiresAt: Date?
        switch resolved {
        case .doNotRemember: return
        case .expires(let date): expiresAt = date
        case .forever: expiresAt = nil
        }
        try? databaseManager.saveRunDecision(
            appIdentifier: pending.appIdentifier,
            subcommand: scope,
            profileSlug: pending.profileSlug,
            expiresAt: expiresAt,
            allowed: allowed,
            appTeamID: pending.appTeamID
        )
    }

    private func showNextRequest() {
        pruneSessionCache()
        while let pending = requestQueue.first {
            requestQueue.removeFirst()
            if let match = anyCachedMatch(
                appIdentifier: pending.appIdentifier,
                profileSlug: pending.profileSlug,
                scopeOptions: pending.scopeOptions.map(\.key)
            ) {
                logDecision(
                    appIdentifier: pending.appIdentifier,
                    profile: pending.profileSlug,
                    command: match.scope,
                    allowed: match.allowed,
                    source: "cached"
                )
                pending.continuation.resume(returning: .cached(match))
                continue
            }
            currentRequest = pending
            isShowingDialog = true
            presentDialog(for: pending)
            return
        }
        isShowingDialog = false
        currentRequest = nil
    }

    private func dismissAndShowNext() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        showNextRequest()
    }

    private func enqueueAuthorization(
        identity: ResolvedIdentity,
        request: RunProxyRequest,
        profileName: String,
        scopeOptions: [RunAuthorizationScope]
    ) async -> DialogOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<DialogOutcome, Never>) in
            let pending = PendingRunAuthRequest(
                appName: identity.appName,
                appBundleURL: identity.appBundleURL,
                profileName: profileName,
                profileSlug: request.profile,
                scopeOptions: scopeOptions,
                fullCommand: request.command.joined(separator: " "),
                appIdentifier: identity.appIdentifier,
                appTeamID: identity.appTeamID,
                continuation: continuation
            )
            requestQueue.append(pending)
            if !isShowingDialog {
                showNextRequest()
            }
        }
    }

    func logDecision(
        appIdentifier: String,
        profile: String,
        command: String,
        allowed: Bool,
        source: String
    ) {
        let decision = allowed ? "allow" : "deny"
        let message = "Run exec: app=\(appIdentifier) profile=\(profile) command=\(command) decision=\(decision) source=\(source)"
        AppLogger.audit.log("\(message, privacy: .public)")
    }
}

@MainActor
private extension RunAuthWindowController {
    private func presentDialog(for pending: PendingRunAuthRequest) {
        let request = RunAuthRequest(
            appName: pending.appName,
            appBundleURL: pending.appBundleURL,
            profileName: pending.profileName,
            command: pending.fullCommand,
            scopeOptions: pending.scopeOptions,
            keychainService: keychainService,
            callbacks: callbacks
        ) { [weak self] allowed, duration, chosenScope in
            self?.completeDialogRequest(
                pending, allowed: allowed, duration: duration, chosenScope: chosenScope
            )
        }
        if let dialogPresenter {
            dialogPresenter(request)
            return
        }
        let hostingController = NSHostingController(rootView: RunAuthDialogView(request: request))
        self.hostingController = hostingController
        panel = makePanel(for: hostingController)
    }

    private func completeDialogRequest(
        _ pending: PendingRunAuthRequest,
        allowed: Bool,
        duration: RememberDuration,
        chosenScope: String?
    ) {
        // A cancelled or already completed prompt cannot act on a later request.
        guard currentRequest?.id == pending.id else { return }
        currentRequest = nil
        var persistedScope: String?
        if let scope = chosenScope, pending.scopeOptions.contains(where: { $0.key == scope }) {
            storeSessionCache(
                appIdentifier: pending.appIdentifier,
                profileSlug: pending.profileSlug,
                scope: scope,
                allowed: allowed
            )
            let resolved = duration.resolved()
            if case .doNotRemember = resolved {
                // Session cache covers the rapid-fire burst; skip DB persist.
            } else {
                persist(decisionFor: pending, resolved: resolved, scope: scope, allowed: allowed)
                persistedScope = scope
            }
        }
        pending.continuation.resume(
            returning: .dialog(allowed: allowed, persistedScope: persistedScope)
        )
        dismissAndShowNext()
    }

    private func makePanel(for hostingController: NSHostingController<RunAuthDialogView>) -> NSPanel {
        // swiftlint:disable identifier_name
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = String(localized: "Command Authorization")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = hostingController.view

        let size = hostingController.sizeThatFits(in: CGSize(width: 380, height: 600))
        if let screen = NSScreen.main {
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.midY - size.height - 40
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return panel
        // swiftlint:enable identifier_name
    }
}
