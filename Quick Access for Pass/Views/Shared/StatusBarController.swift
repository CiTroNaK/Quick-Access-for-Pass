import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let healthStore: ProxyHealthStore
    private let passCLIStatusStore: PassCLIStatusStore
    private let onToggle: () -> Void
    private let onRefresh: () -> Void
    private let onLoginPassCLI: () -> Void
    private let onQuit: () -> Void
    private let onOpenSettings: (OpenSettingsAction, NSRunningApplication?) -> Void
    private let frontmostApplication: () -> NSRunningApplication?

    private var currentStatus: MenuBarStatus = .normal

    init(
        healthStore: ProxyHealthStore,
        passCLIStatusStore: PassCLIStatusStore,
        onToggle: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onLoginPassCLI: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onOpenSettings: @escaping (OpenSettingsAction, NSRunningApplication?) -> Void,
        frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        makeStatusItem: () -> NSStatusItem? = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
    ) {
        self.healthStore = healthStore
        self.passCLIStatusStore = passCLIStatusStore
        self.onToggle = onToggle
        self.onRefresh = onRefresh
        self.onLoginPassCLI = onLoginPassCLI
        self.onQuit = onQuit
        self.onOpenSettings = onOpenSettings
        self.frontmostApplication = frontmostApplication
        super.init()

        statusItem = makeStatusItem()

        if let button = statusItem?.button {
            button.image = Self.compositeIcon(for: .normal)
            button.toolTip = Self.tooltip(for: .normal)
            button.setAccessibilityLabel(Self.tooltip(for: .normal))
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        startObserving()
    }

    // MARK: - Observation

    private func startObserving() {
        withObservationTracking {
            _ = healthStore.sshHealth
            _ = healthStore.runHealth
            _ = passCLIStatusStore.health
            _ = passCLIStatusStore.recommendedVersionWarning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.startObserving()
            }
        }
    }

    private func updateIcon() {
        let status = MenuBarHealthAggregator.aggregate(
            sshHealth: healthStore.sshHealth,
            runHealth: healthStore.runHealth,
            cliHealth: passCLIStatusStore.health,
            cliRecommendedVersionWarning: passCLIStatusStore.recommendedVersionWarning != nil
        )
        guard status != currentStatus else { return }
        let oldStatus = currentStatus
        currentStatus = status
        statusItem?.button?.image = Self.compositeIcon(for: status)
        statusItem?.button?.toolTip = Self.tooltip(for: status)
        statusItem?.button?.setAccessibilityLabel(Self.tooltip(for: status))
        announceIfWorsening(old: oldStatus, new: status)
    }

    private func announceIfWorsening(old: MenuBarStatus, new: MenuBarStatus) {
        guard new.severityRank > old.severityRank else { return }
        let message: String
        switch new {
        case .normal:    return
        case .degraded:  message = String(localized: "Quick Access for Pass: service warning")
        case .error:     message = String(localized: "Quick Access for Pass: service error")
        }
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Icon Composition

    private static func compositeIcon(for status: MenuBarStatus) -> NSImage {
        let size = NSSize(width: 18, height: 18)

        guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else {
            return NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Quick Access for Pass")!
        }

        let badgeName: String
        let badgeColor: NSColor
        switch status {
        case .normal:
            let image = NSImage(size: size, flipped: false) { rect in
                bolt.draw(in: Self.centeredRect(for: bolt.size, in: rect))
                return true
            }
            image.isTemplate = true
            return image
        case .degraded:
            badgeName = "exclamationmark.triangle.fill"
            badgeColor = .systemOrange
        case .error:
            badgeName = "xmark.circle.fill"
            badgeColor = .systemRed
        }

        guard let badge = NSImage(systemSymbolName: badgeName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold, scale: .small)
                .applying(.init(paletteColors: [badgeColor]))) else {
            let image = NSImage(size: size, flipped: false) { rect in
                bolt.draw(in: Self.centeredRect(for: bolt.size, in: rect))
                return true
            }
            image.isTemplate = true
            return image
        }

        let image = NSImage(size: size, flipped: false) { rect in
            bolt.draw(in: Self.centeredRect(for: bolt.size, in: rect))
            let badgeSize = badge.size
            let badgeRect = NSRect(
                x: rect.maxX - badgeSize.width - 0.5,
                y: 0.5,
                width: badgeSize.width,
                height: badgeSize.height
            )
            badge.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func centeredRect(for imageSize: NSSize, in rect: NSRect) -> NSRect {
        NSRect(
            x: rect.midX - imageSize.width / 2,
            y: rect.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    // MARK: - Tooltip

    private static func tooltip(for status: MenuBarStatus) -> String {
        switch status {
        case .normal:
            return String(localized: "Quick Access for Pass")
        case .degraded(let services):
            return String(localized: "Quick Access for Pass — Warning: \(services.joined(separator: ", "))")
        case .error(let services):
            return String(localized: "Quick Access for Pass — Error: \(services.joined(separator: ", "))")
        }
    }

    // MARK: - Button Actions

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            onToggle()
        }
    }

    private func showMenu() {
        let menu = makeMenu()
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Creates a short-lived menu and captures foreground identity before menu activation.
    func makeMenu() -> NSMenu {
        let application = frontmostApplication()
        let restorationTarget = application?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : application
        let onOpenSettings = onOpenSettings
        return NSHostingMenu(rootView: StatusBarMenuContent(
            cliHealth: passCLIStatusStore.health,
            recommendedVersionWarning: passCLIStatusStore.recommendedVersionWarning,
            sshHealth: healthStore.sshHealth,
            runHealth: healthStore.runHealth,
            onRefresh: onRefresh,
            onLoginPassCLI: onLoginPassCLI,
            onQuit: onQuit,
            onOpenSettings: { onOpenSettings($0, restorationTarget) }
        ))
    }
}
