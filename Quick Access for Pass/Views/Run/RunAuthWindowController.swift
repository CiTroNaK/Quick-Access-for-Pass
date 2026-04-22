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
    private let callbacks: AuthDialogHelper.Callbacks
    var sessionCache: [String: Date] = [:]
    let sessionCacheDuration: TimeInterval = 10

    private nonisolated enum DialogOutcome: Sendable {
        case dialog(allowed: Bool, persistedScope: String?)
        case cached(scope: String)
    }

    private struct PendingRunAuthRequest {
        let appName: String
        let appBundleURL: URL?
        let profileName: String
        let profileSlug: String
        let scopeOptions: [String]
        let fullCommand: String
        let appIdentifier: String
        let appTeamID: String?
        let continuation: CheckedContinuation<DialogOutcome, Never>
    }

    init(databaseManager: DatabaseManager, keychainService: any BiometricAuthorizing, callbacks: AuthDialogHelper.Callbacks) {
        self.databaseManager = databaseManager
        self.keychainService = keychainService
        self.callbacks = callbacks
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

        let scopeOptions = Self.scopeOptions(from: request.command)

        if let matchedScope = anyCachedMatch(
            appIdentifier: identity.appIdentifier,
            profileSlug: request.profile,
            scopeOptions: scopeOptions
        ) {
            logDecision(
                appIdentifier: identity.appIdentifier,
                profile: request.profile,
                command: matchedScope,
                allowed: true,
                source: "cached"
            )
            return RunProxyResponse(decision: .allow, env: env)
        }

        let outcome = await enqueueAuthorization(
            identity: identity,
            request: request,
            profileName: profileName,
            scopeOptions: scopeOptions
        )

        switch outcome {
        case .cached:
            return RunProxyResponse(decision: .allow, env: env)
        case .dialog(let allowed, let persistedScope):
            logDecision(
                appIdentifier: identity.appIdentifier,
                profile: request.profile,
                command: persistedScope ?? scopeOptions.first ?? "",
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
        scope: String
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
            appTeamID: pending.appTeamID
        )
    }

    private func showNextRequest() {
        pruneSessionCache()
        while let pending = requestQueue.first {
            requestQueue.removeFirst()
            if let matchedScope = anyCachedMatch(
                appIdentifier: pending.appIdentifier,
                profileSlug: pending.profileSlug,
                scopeOptions: pending.scopeOptions
            ) {
                logDecision(
                    appIdentifier: pending.appIdentifier,
                    profile: pending.profileSlug,
                    command: matchedScope,
                    allowed: true,
                    source: "cached"
                )
                pending.continuation.resume(returning: .cached(scope: matchedScope))
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

    private func presentDialog(for pending: PendingRunAuthRequest) {
        let request = RunAuthRequest(
            appName: pending.appName,
            appBundleURL: pending.appBundleURL,
            profileName: pending.profileName,
            command: pending.fullCommand,
            scopeOptions: pending.scopeOptions,
            keychainService: self.keychainService,
            callbacks: self.callbacks
        ) { [weak self] allowed, duration, chosenScope in
            Task { @MainActor [weak self] in
                guard let self else {
                    pending.continuation.resume(
                        returning: .dialog(allowed: allowed, persistedScope: nil)
                    )
                    return
                }
                var persistedScope: String?
                if allowed, let scope = chosenScope {
                    self.storeSessionCache(
                        appIdentifier: pending.appIdentifier,
                        profileSlug: pending.profileSlug,
                        scope: scope
                    )
                    let resolved = duration.resolved()
                    if case .doNotRemember = resolved {
                        // Session cache covers the rapid-fire burst; skip DB persist.
                    } else {
                        self.persist(decisionFor: pending, resolved: resolved, scope: scope)
                        persistedScope = scope
                    }
                }
                pending.continuation.resume(
                    returning: .dialog(allowed: allowed, persistedScope: persistedScope)
                )
                self.dismissAndShowNext()
            }
        }

        let dialogView = RunAuthDialogView(request: request)
        let hc = NSHostingController(rootView: dialogView)
        hostingController = hc

        // swiftlint:disable identifier_name
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.title = String(localized: "Command Authorization")
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.contentView = hc.view

        let size = hc.sizeThatFits(in: CGSize(width: 380, height: 600))
        if let screen = NSScreen.main {
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.midY - size.height - 40
            p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }

        p.makeKeyAndOrderFront(nil)
        NSApp.activate()
        panel = p
        // swiftlint:enable identifier_name
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
        scopeOptions: [String]
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
