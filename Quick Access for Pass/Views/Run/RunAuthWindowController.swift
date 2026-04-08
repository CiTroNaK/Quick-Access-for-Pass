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
    private let databaseManager: DatabaseManager
    private let keychainService: any BiometricAuthorizing
    private let callbacks: AuthDialogHelper.Callbacks

    private struct PendingRunAuthRequest {
        let appName: String
        let appBundleURL: URL?
        let profileName: String
        let profileSlug: String
        let subcommand: String
        let fullCommand: String
        let appIdentifier: String
        let appTeamID: String?
        let continuation: CheckedContinuation<Bool, Never>
    }

    init(databaseManager: DatabaseManager, keychainService: any BiometricAuthorizing, callbacks: AuthDialogHelper.Callbacks) {
        self.databaseManager = databaseManager
        self.keychainService = keychainService
        self.callbacks = callbacks
    }

    static func extractSubcommand(from command: [String]) -> String {
        var tokens: [String] = []
        for token in command {
            if token.hasPrefix("-") { break }
            tokens.append(token)
            if tokens.count == 3 { break }
        }
        return tokens.joined(separator: " ")
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

        let subcommand = Self.extractSubcommand(from: request.command)
        if isPersistentlyAuthorized(
            appIdentifier: identity.appIdentifier,
            subcommand: subcommand,
            profileSlug: request.profile
        ) {
            logDecision(
                appIdentifier: identity.appIdentifier,
                profile: request.profile,
                command: subcommand,
                allowed: true,
                source: "cached"
            )
            return RunProxyResponse(decision: .allow, env: env)
        }

        let allowed = await enqueueAuthorization(
            identity: identity,
            request: request,
            profileName: profileName,
            subcommand: subcommand
        )

        logDecision(
            appIdentifier: identity.appIdentifier,
            profile: request.profile,
            command: subcommand,
            allowed: allowed,
            source: "dialog"
        )
        return allowed
            ? RunProxyResponse(decision: .allow, env: env)
            : RunProxyResponse(decision: .deny, env: nil)
    }

    func cancelAll() {
        if let current = currentRequest {
            current.continuation.resume(returning: false)
            currentRequest = nil
        }
        for pending in requestQueue {
            pending.continuation.resume(returning: false)
        }
        requestQueue.removeAll()
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        isShowingDialog = false
    }

    private func persist(decisionFor pending: PendingRunAuthRequest, resolved: ResolvedRemember) {
        let expiresAt: Date?
        switch resolved {
        case .doNotRemember: return
        case .expires(let date): expiresAt = date
        case .forever: expiresAt = nil
        }
        try? databaseManager.saveRunDecision(
            appIdentifier: pending.appIdentifier,
            subcommand: pending.subcommand,
            profileSlug: pending.profileSlug,
            expiresAt: expiresAt,
            appTeamID: pending.appTeamID
        )
    }

    private func showNextRequest() {
        guard let pending = requestQueue.first else {
            isShowingDialog = false
            currentRequest = nil
            return
        }
        requestQueue.removeFirst()
        currentRequest = pending
        isShowingDialog = true

        let request = RunAuthRequest(
            appName: pending.appName,
            appBundleURL: pending.appBundleURL,
            profileName: pending.profileName,
            command: pending.fullCommand,
            keychainService: self.keychainService,
            callbacks: self.callbacks
        ) { [weak self] allowed, duration in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if allowed {
                    self.persist(decisionFor: pending, resolved: duration.resolved())
                }
                pending.continuation.resume(returning: allowed)
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

    private struct ResolvedIdentity {
        let appName: String
        let appBundleURL: URL?
        let appIdentifier: String
        let appTeamID: String?
    }

    private func resolveIdentity(
        for connection: VerifiedConnection,
        profile: String
    ) -> ResolvedIdentity? {
        switch connection.identity {
        case .trustedHelper:
            let parentInfo = ProcessIdentifier.identifyParent(of: connection)
            return ResolvedIdentity(
                appName: parentInfo.name,
                appBundleURL: parentInfo.bundleURL,
                appIdentifier: parentInfo.bundleIdentifier ?? "unknown",
                appTeamID: nil
            )

        case .signedApp(let bundleID, let teamID):
            let runningApp = NSRunningApplication(processIdentifier: connection.pid)
            return ResolvedIdentity(
                appName: runningApp?.localizedName ?? bundleID,
                appBundleURL: runningApp?.bundleURL,
                appIdentifier: connection.identity.appIdentifier ?? bundleID,
                appTeamID: teamID
            )

        case .unverified:
            logDecision(
                appIdentifier: "unverified.\(connection.pid)",
                profile: profile,
                command: "",
                allowed: false,
                source: "rejected"
            )
            return nil
        }
    }

    private func isPersistentlyAuthorized(
        appIdentifier: String,
        subcommand: String,
        profileSlug: String
    ) -> Bool {
        (try? databaseManager.findValidRunDecision(
            appIdentifier: appIdentifier,
            subcommand: subcommand,
            profileSlug: profileSlug
        )) != nil
    }

    private func enqueueAuthorization(
        identity: ResolvedIdentity,
        request: RunProxyRequest,
        profileName: String,
        subcommand: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let pending = PendingRunAuthRequest(
                appName: identity.appName,
                appBundleURL: identity.appBundleURL,
                profileName: profileName,
                profileSlug: request.profile,
                subcommand: subcommand,
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

    private func logDecision(
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
