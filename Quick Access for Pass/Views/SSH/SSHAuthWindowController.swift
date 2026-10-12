import AppKit
import SwiftUI
import os

@MainActor
final class SSHAuthWindowController {
    /// Uses the same app/command/host identity as persisted decisions without merging key components.
    private nonisolated struct SessionCacheKey: Hashable, Sendable {
        let authorizationID: String
        let fingerprint: String
    }

    private struct AuthorizationContext {
        let clientInfo: SSHClientInfo
        let appId: String
        let appTeamID: String?
        let persistentCacheId: String
        let fingerprint: String
    }

    private struct PendingAuthRequest {
        let id = UUID()
        let clientInfo: SSHClientInfo
        let appId: String
        let persistentCacheId: String
        let fingerprint: String
        let keyBlob: Data
        let appTeamID: String?
        let continuation: CheckedContinuation<SSHAuthorizationResult, Never>
    }

    private var activeHeaderModel: RequesterHeaderModel?
    private let headerFactory: @MainActor (SSHClientInfo) -> RequesterHeaderModel?
    private var panel: NSPanel?
    private var hostingController: NSHostingController<SSHAuthDialogView>?
    private var requestQueue: [PendingAuthRequest] = []
    private var currentRequest: PendingAuthRequest?
    private var isShowingDialog = false
    private let databaseManager: DatabaseManager
    private let keychainService: any BiometricAuthorizing
    private let callbacks: AuthDialogHelper.Callbacks
    private let identifyRequester: @MainActor (VerifiedConnection) -> SSHClientInfo
    private let presentDialog: (@MainActor (SSHAuthRequest) -> Void)?
    var batchModeNotifier: SSHBatchModeNotifier?
    private var sessionCache: [SessionCacheKey: (allowed: Bool, expiresAt: Date)] = [:]
    private let sessionCacheDuration: TimeInterval = 3

    init(
        databaseManager: DatabaseManager,
        keychainService: any BiometricAuthorizing,
        callbacks: AuthDialogHelper.Callbacks,
        identifyRequester: @escaping @MainActor (VerifiedConnection) -> SSHClientInfo = ProcessIdentifier.identifyRequester(of:),
        presentDialog: (@MainActor (SSHAuthRequest) -> Void)? = nil,
        headerFactory: @escaping @MainActor (SSHClientInfo) -> RequesterHeaderModel? = { _ in nil }
    ) {
        self.databaseManager = databaseManager
        self.keychainService = keychainService
        self.callbacks = callbacks
        self.identifyRequester = identifyRequester
        self.presentDialog = presentDialog
        self.headerFactory = headerFactory
    }

    /// Returns a cached authorization outcome without displaying a prompt.
    func cachedAuthorizationResult(
        for keyBlob: Data,
        connection: VerifiedConnection
    ) -> SSHAuthorizationResult? {
        let context = makeAuthorizationContext(keyBlob: keyBlob, connection: connection)
        let now = Date()
        sessionCache = sessionCache.filter { $0.value.expiresAt > now }

        if let allowed = cachedDecision(
            cacheID: context.persistentCacheId,
            fingerprint: context.fingerprint,
            now: now
        ) {
            logDecision(
                appId: context.appId,
                fingerprint: context.fingerprint,
                host: context.clientInfo.triggerCommand ?? "unknown",
                allowed: allowed,
                source: "cached"
            )
            return allowed ? .allow : .deny
        }

        return nil
    }

    func authorize(keyBlob: Data, connection: VerifiedConnection) async -> SSHAuthorizationResult {
        if let result = cachedAuthorizationResult(for: keyBlob, connection: connection) {
            return result
        }

        let context = makeAuthorizationContext(keyBlob: keyBlob, connection: connection)
        if context.clientInfo.batchMode {
            return handleBatchMode(keyBlob: keyBlob, context: context)
        }

        return await enqueueAuthorization(context: context, keyBlob: keyBlob)
    }

    func cancelAll() {
        activeHeaderModel?.cancel()
        activeHeaderModel = nil
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
        drainCacheCoveredRequests()

        guard let pending = nextPendingRequest() else {
            isShowingDialog = false
            currentRequest = nil
            return
        }

        currentRequest = pending
        isShowingDialog = true

        let request = makeDialogRequest(for: pending)
        if let presentDialog {
            presentDialog(request)
            return
        }
        let dialogView = SSHAuthDialogView(request: request)
        let hostingController = NSHostingController(rootView: dialogView)
        self.hostingController = hostingController
        panel = makePanel(for: hostingController)
    }

    private func dismissAndShowNext() {
        activeHeaderModel?.cancel()
        activeHeaderModel = nil
        currentRequest = nil
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
        let clientInfo = identifyRequester(connection)
        let identity = SSHAuthorizationIdentity(connection: connection, clientInfo: clientInfo)
        return AuthorizationContext(
            clientInfo: clientInfo,
            appId: identity.requesterAppID,
            appTeamID: identity.appTeamID,
            persistentCacheId: identity.persistentCacheID,
            fingerprint: keyBlob.sha256Hex
        )
    }

    /// Prefers a live session decision only for the exact persisted authorization context.
    private func cachedDecision(cacheID: String, fingerprint: String, now: Date) -> Bool? {
        let key = SessionCacheKey(authorizationID: cacheID, fingerprint: fingerprint)
        if let decision = sessionCache[key], decision.expiresAt > now {
            return decision.allowed
        }
        return (try? databaseManager.findValidDecision(
            appIdentifier: cacheID,
            keyFingerprint: fingerprint
        ))?.allowed
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

    private func drainCacheCoveredRequests() {
        let now = Date()
        while let pending = requestQueue.first {
            guard let allowed = cachedDecision(
                cacheID: pending.persistentCacheId,
                fingerprint: pending.fingerprint,
                now: now
            ) else { break }
            requestQueue.removeFirst()
            logDecision(
                appId: pending.appId,
                fingerprint: pending.fingerprint,
                host: pending.clientInfo.triggerCommand ?? "unknown",
                allowed: allowed,
                source: "cached"
            )
            pending.continuation.resume(returning: allowed ? .allow : .deny)
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

        let header = headerFactory(pending.clientInfo)
        activeHeaderModel = header
        return SSHAuthRequest(
            appName: pending.clientInfo.name,
            appBundleURL: pending.clientInfo.bundleURL,
            headerModel: header,
            keyName: keyName,
            triggerCommand: pending.clientInfo.triggerCommand,
            showCommand: pending.clientInfo.showCommand,
            host: host,
            keychainService: self.keychainService,
            callbacks: self.callbacks,
            onContentHeightChange: { [weak self] height in
                guard let self, self.currentRequest?.id == pending.id, let panel = self.panel else { return }
                AuthorizationPanelSizing.resize(panel, contentHeight: height)
            },
            onResult: { [weak self] allowed, duration in
                Task { @MainActor [weak self] in
                    self?.completeDialogRequest(pending, allowed: allowed, duration: duration)
                }
            }
        )
    }

    private func completeDialogRequest(
        _ pending: PendingAuthRequest,
        allowed: Bool,
        duration: RememberDuration
    ) {
        guard currentRequest?.id == pending.id else { return }
        let sessionKey = SessionCacheKey(
            authorizationID: pending.persistentCacheId,
            fingerprint: pending.fingerprint
        )
        sessionCache[sessionKey] = (
            allowed: allowed,
            expiresAt: Date().addingTimeInterval(sessionCacheDuration)
        )

        switch duration.resolved() {
        case .doNotRemember:
            break
        case .expires(let expiresAt):
            try? databaseManager.saveDecision(
                appIdentifier: pending.persistentCacheId,
                keyFingerprint: pending.fingerprint,
                expiresAt: expiresAt,
                allowed: allowed,
                appTeamID: pending.appTeamID
            )
        case .forever:
            try? databaseManager.saveDecision(
                appIdentifier: pending.persistentCacheId,
                keyFingerprint: pending.fingerprint,
                expiresAt: nil,
                allowed: allowed,
                appTeamID: pending.appTeamID
            )
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
