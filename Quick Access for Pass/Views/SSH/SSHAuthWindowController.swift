import AppKit
import SwiftUI
import os

@MainActor
final class SSHAuthWindowController {
    private struct AuthorizationContext {
        let clientInfo: SSHClientInfo
        let appId: String
        let appTeamID: String?
        let persistentCacheId: String
        let fingerprint: String
    }

    private struct PendingAuthRequest {
        let clientInfo: SSHClientInfo
        let appId: String
        let persistentCacheId: String
        let fingerprint: String
        let keyBlob: Data
        let appTeamID: String?
        let continuation: CheckedContinuation<SSHAuthorizationResult, Never>
    }

    private var panel: NSPanel?
    private var hostingController: NSHostingController<SSHAuthDialogView>?
    private var requestQueue: [PendingAuthRequest] = []
    private var currentRequest: PendingAuthRequest?
    private var isShowingDialog = false
    private let databaseManager: DatabaseManager
    private let keychainService: any BiometricAuthorizing
    private let callbacks: AuthDialogHelper.Callbacks
    var batchModeNotifier: SSHBatchModeNotifier?
    private var sessionCache: [String: Date] = [:]
    private let sessionCacheDuration: TimeInterval = 3

    init(databaseManager: DatabaseManager, keychainService: any BiometricAuthorizing, callbacks: AuthDialogHelper.Callbacks) {
        self.databaseManager = databaseManager
        self.keychainService = keychainService
        self.callbacks = callbacks
    }

    func authorize(keyBlob: Data, connection: VerifiedConnection) async -> SSHAuthorizationResult {
        let context = makeAuthorizationContext(keyBlob: keyBlob, connection: connection)

        let now = Date()
        sessionCache = sessionCache.filter { $0.value > now }

        if isSessionAuthorized(appId: context.appId, fingerprint: context.fingerprint, now: now) {
            logDecision(
                appId: context.appId,
                fingerprint: context.fingerprint,
                host: context.clientInfo.triggerCommand ?? "unknown",
                allowed: true,
                source: "cached"
            )
            return .allow
        }

        if isPersistentlyAuthorized(
            cacheID: context.persistentCacheId,
            fingerprint: context.fingerprint
        ) {
            logDecision(
                appId: context.appId,
                fingerprint: context.fingerprint,
                host: context.clientInfo.triggerCommand ?? "unknown",
                allowed: true,
                source: "cached"
            )
            return .allow
        }

        if context.clientInfo.batchMode {
            return handleBatchMode(keyBlob: keyBlob, context: context)
        }

        return await enqueueAuthorization(context: context, keyBlob: keyBlob)
    }

    func cancelAll() {
        if let current = currentRequest {
            current.continuation.resume(returning: .deny)
            currentRequest = nil
        }
        for pending in requestQueue {
            pending.continuation.resume(returning: .deny)
        }
        requestQueue.removeAll()
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        isShowingDialog = false
    }

    private func showNextRequest() {
        drainSessionCoveredRequests()

        guard let pending = nextPendingRequest() else {
            isShowingDialog = false
            currentRequest = nil
            return
        }

        currentRequest = pending
        isShowingDialog = true

        let request = makeDialogRequest(for: pending)
        let dialogView = SSHAuthDialogView(request: request)
        let hostingController = NSHostingController(rootView: dialogView)
        self.hostingController = hostingController
        panel = makePanel(for: hostingController)
    }

    private func dismissAndShowNext() {
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        showNextRequest()
    }
}

@MainActor
private extension SSHAuthWindowController {
    private func makeAuthorizationContext(
        keyBlob: Data,
        connection: VerifiedConnection
    ) -> AuthorizationContext {
        let clientInfo = ProcessIdentifier.identifyRequester(of: connection)
        let identity = SSHAuthorizationIdentity(connection: connection, clientInfo: clientInfo)
        return AuthorizationContext(
            clientInfo: clientInfo,
            appId: identity.requesterAppID,
            appTeamID: identity.appTeamID,
            persistentCacheId: identity.persistentCacheID,
            fingerprint: keyBlob.sha256Hex
        )
    }

    private func isSessionAuthorized(appId: String, fingerprint: String, now: Date) -> Bool {
        let sessionKey = "\(appId):\(fingerprint)"
        guard let sessionExpiry = sessionCache[sessionKey] else { return false }
        return sessionExpiry > now
    }

    private func isPersistentlyAuthorized(cacheID: String, fingerprint: String) -> Bool {
        (try? databaseManager.findValidDecision(
            appIdentifier: cacheID,
            keyFingerprint: fingerprint
        )) != nil
    }

    private func handleBatchMode(
        keyBlob: Data,
        context: AuthorizationContext
    ) -> SSHAuthorizationResult {
        guard let host = context.clientInfo.command.flatMap({ ProcessIdentifier.parseHost($0) }) else {
            logDecision(
                appId: context.appId,
                fingerprint: context.fingerprint,
                host: "unknown",
                allowed: false,
                source: "batchMode"
            )
            return .deny
        }

        if let decision = try? databaseManager.findBatchModeDecision(
            keyFingerprint: context.fingerprint,
            host: host
        ) {
            logDecision(
                appId: context.appId,
                fingerprint: context.fingerprint,
                host: context.clientInfo.triggerCommand ?? host,
                allowed: decision.allowed,
                source: "batchMode"
            )
            return decision.allowed ? .allow : .deny
        }

        let keyName = SSHKeyNameCache.shared.name(for: keyBlob)
        batchModeNotifier?.postBlockedProbeNotification(
            keyFingerprint: context.fingerprint,
            host: host,
            keyName: keyName,
            appIdentifier: context.appId,
            appTeamID: context.appTeamID
        )
        logDecision(
            appId: context.appId,
            fingerprint: context.fingerprint,
            host: context.clientInfo.triggerCommand ?? host,
            allowed: false,
            source: "batchMode"
        )
        return .deny
    }

    private func enqueueAuthorization(
        context: AuthorizationContext,
        keyBlob: Data
    ) async -> SSHAuthorizationResult {
        await withCheckedContinuation { continuation in
            let pending = PendingAuthRequest(
                clientInfo: context.clientInfo,
                appId: context.appId,
                persistentCacheId: context.persistentCacheId,
                fingerprint: context.fingerprint,
                keyBlob: keyBlob,
                appTeamID: context.appTeamID,
                continuation: continuation
            )
            requestQueue.append(pending)
            if !isShowingDialog {
                showNextRequest()
            }
        }
    }

    private func drainSessionCoveredRequests() {
        while let pending = requestQueue.first {
            let sessionKey = "\(pending.appId):\(pending.fingerprint)"
            if let expiry = sessionCache[sessionKey], expiry > Date() {
                requestQueue.removeFirst()
                pending.continuation.resume(returning: .allow)
                continue
            }
            break
        }
    }

    private func nextPendingRequest() -> PendingAuthRequest? {
        guard let pending = requestQueue.first else { return nil }
        requestQueue.removeFirst()
        return pending
    }

    private func makeDialogRequest(for pending: PendingAuthRequest) -> SSHAuthRequest {
        let keyName = SSHKeyNameCache.shared.name(for: pending.keyBlob)
            ?? "Key \(pending.fingerprint.prefix(16))..."
        let host = pending.clientInfo.command.flatMap { ProcessIdentifier.parseHost($0) }

        return SSHAuthRequest(
            appName: pending.clientInfo.name,
            appBundleURL: pending.clientInfo.bundleURL,
            keyName: keyName,
            triggerCommand: pending.clientInfo.triggerCommand,
            showCommand: pending.clientInfo.showCommand,
            host: host,
            keychainService: self.keychainService,
            callbacks: self.callbacks
        ) { [weak self] allowed, duration in
            Task { @MainActor [weak self] in
                self?.completeDialogRequest(pending, allowed: allowed, duration: duration)
            }
        }
    }

    private func completeDialogRequest(
        _ pending: PendingAuthRequest,
        allowed: Bool,
        duration: RememberDuration
    ) {
        if allowed {
            let sessionKey = "\(pending.appId):\(pending.fingerprint)"
            sessionCache[sessionKey] = Date().addingTimeInterval(sessionCacheDuration)

            switch duration.resolved() {
            case .doNotRemember:
                break
            case .expires(let expiresAt):
                try? databaseManager.saveDecision(
                    appIdentifier: pending.persistentCacheId,
                    keyFingerprint: pending.fingerprint,
                    expiresAt: expiresAt,
                    appTeamID: pending.appTeamID
                )
            case .forever:
                try? databaseManager.saveDecision(
                    appIdentifier: pending.persistentCacheId,
                    keyFingerprint: pending.fingerprint,
                    expiresAt: nil,
                    appTeamID: pending.appTeamID
                )
            }
        }

        logDecision(
            appId: pending.appId,
            fingerprint: pending.fingerprint,
            host: pending.clientInfo.triggerCommand ?? "unknown",
            allowed: allowed,
            source: "dialog"
        )
        pending.continuation.resume(returning: allowed ? .allow : .deny)
        dismissAndShowNext()
    }

    private func makePanel(for hostingController: NSHostingController<SSHAuthDialogView>) -> NSPanel {
        // swiftlint:disable identifier_name
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.title = String(localized: "SSH Key Authorization")
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.contentView = hostingController.view

        let size = hostingController.sizeThatFits(in: CGSize(width: 380, height: 600))
        if let screen = NSScreen.main {
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.midY - size.height - 40
            p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }

        p.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return p
        // swiftlint:enable identifier_name
    }

    private func logDecision(
        appId: String,
        fingerprint: String,
        host: String,
        allowed: Bool,
        source: String
    ) {
        let decision = allowed ? "allow" : "deny"
        let message = "SSH sign: app=\(appId) fingerprint=\(fingerprint) host=\(host) decision=\(decision) source=\(source)"
        AppLogger.audit.log("\(message, privacy: .public)")
    }
}
