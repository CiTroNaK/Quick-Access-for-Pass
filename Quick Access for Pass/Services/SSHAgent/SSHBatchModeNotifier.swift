import Foundation
import UserNotifications
import os

@MainActor
final class SSHBatchModeNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let databaseManager: DatabaseManager
    private nonisolated let nonceStore = OSAllocatedUnfairLock(initialState: NonceStore())

    private var pendingProbes: [String: PendingProbe] = [:]

    nonisolated struct NonceStore: Sendable {
        private static let ttl: TimeInterval = 120
        private var entries: [String: (keyFingerprints: [String], registeredAt: Date)] = [:]

        mutating func register(nonce: String, keyFingerprints: [String], at date: Date = Date()) {
            entries[nonce] = (keyFingerprints, date)
        }

        mutating func validate(nonce: String) -> [String]? {
            guard let entry = entries.removeValue(forKey: nonce) else { return nil }
            guard Date().timeIntervalSince(entry.registeredAt) < Self.ttl else { return nil }
            return entry.keyFingerprints
        }
    }

    private struct PendingFingerprint: Sendable {
        let fingerprint: String
        let keyName: String?
        let appIdentifier: String?
        let appTeamID: String?
    }

    private struct PendingProbe {
        var fingerprints: [PendingFingerprint]
        let workItem: DispatchWorkItem
    }

    private static let categoryIdentifier = "SSH_BATCH_MODE"
    private static let allowActionIdentifier = "ALLOW"
    private static let denyActionIdentifier = "DENY"

    nonisolated static func makeNotificationIdentifier(host: String) -> String {
        "ssh-batch-\(host)-\(UUID().uuidString)"
    }

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        super.init()
        setupNotificationCategory()
    }

    private func setupNotificationCategory() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let allow = UNNotificationAction(
            identifier: Self.allowActionIdentifier,
            title: String(localized: "Allow"),
            options: []
        )
        let deny = UNNotificationAction(
            identifier: Self.denyActionIdentifier,
            title: String(localized: "Deny"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [allow, deny],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postBlockedProbeNotification(
        keyFingerprint: String,
        host: String,
        keyName: String?,
        appIdentifier: String? = nil,
        appTeamID: String? = nil
    ) {
        let pendingFingerprint = PendingFingerprint(
            fingerprint: keyFingerprint,
            keyName: keyName,
            appIdentifier: appIdentifier,
            appTeamID: appTeamID
        )

        if var existing = pendingProbes[host] {
            existing.fingerprints.append(pendingFingerprint)
            pendingProbes[host] = existing
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.fireNotification(host: host)
        }
        pendingProbes[host] = PendingProbe(
            fingerprints: [pendingFingerprint],
            workItem: workItem
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func fireNotification(host: String) {
        guard let probe = pendingProbes.removeValue(forKey: host) else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "SSH probe blocked")

        if probe.fingerprints.count == 1, let entry = probe.fingerprints.first {
            let displayKey = entry.keyName ?? "Key \(entry.fingerprint.prefix(16))..."
            content.body = String(localized: "\(host) wanted to use key \(displayKey)")
        } else {
            content.body = String(localized: "\(host) wanted to use \(probe.fingerprints.count) keys")
        }

        content.categoryIdentifier = Self.categoryIdentifier

        let fingerprints = probe.fingerprints.map(\.fingerprint)
        let keyNames = probe.fingerprints.map { $0.keyName ?? "" }
        let appIdentifiers = probe.fingerprints.map { $0.appIdentifier ?? "" }
        let appTeamIDs = probe.fingerprints.map { $0.appTeamID ?? "" }
        content.userInfo = [
            "host": host,
            "keyFingerprints": fingerprints,
            "keyNames": keyNames,
            "appIdentifiers": appIdentifiers,
            "appTeamIDs": appTeamIDs,
        ]

        let identifier = Self.makeNotificationIdentifier(host: host)
        nonceStore.withLock { $0.register(nonce: identifier, keyFingerprints: fingerprints) }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let host = userInfo["host"] as? String, !host.isEmpty else {
            completionHandler()
            return
        }

        let allowed: Bool
        switch response.actionIdentifier {
        case Self.allowActionIdentifier:
            allowed = true
        case Self.denyActionIdentifier:
            allowed = false
        default:
            completionHandler()
            return
        }

        let identifier = response.notification.request.identifier
        let fingerprints = nonceStore.withLock { $0.validate(nonce: identifier) }
        guard let fingerprints else {
            completionHandler()
            return
        }

        let keyNames = (userInfo["keyNames"] as? [String]) ?? Array(repeating: "", count: fingerprints.count)
        let appIdentifiers = (userInfo["appIdentifiers"] as? [String]) ?? Array(repeating: "", count: fingerprints.count)
        let appTeamIDs = (userInfo["appTeamIDs"] as? [String]) ?? Array(repeating: "", count: fingerprints.count)
        for (index, fingerprint) in fingerprints.enumerated() {
            let keyNameRaw = index < keyNames.count ? keyNames[index] : ""
            let appIdentifierRaw = index < appIdentifiers.count ? appIdentifiers[index] : ""
            let appTeamIDRaw = index < appTeamIDs.count ? appTeamIDs[index] : ""
            let keyName: String? = keyNameRaw.isEmpty ? nil : keyNameRaw
            let appIdentifier: String? = appIdentifierRaw.isEmpty ? nil : appIdentifierRaw
            let appTeamID: String? = appTeamIDRaw.isEmpty ? nil : appTeamIDRaw
            try? databaseManager.saveBatchModeDecision(
                keyFingerprint: fingerprint,
                host: host,
                keyName: keyName,
                allowed: allowed,
                appIdentifier: appIdentifier,
                appTeamID: appTeamID
            )
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
