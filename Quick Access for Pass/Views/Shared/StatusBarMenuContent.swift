import AppKit
import SwiftUI

/// Snapshot-backed native menu content; obtains Settings from its own SwiftUI environment.
struct StatusBarMenuContent: View {
    let cliHealth: PassCLIHealth
    let recommendedVersionWarning: PassCLIRecommendedVersionWarning?
    let sshHealth: ProxyHealthState
    let runHealth: ProxyHealthState
    let onRefresh: () -> Void
    let onLoginPassCLI: () -> Void
    let onQuit: () -> Void
    let onOpenSettings: (OpenSettingsAction) -> Void

    var body: some View {
        Group {
            cliStatusRow
            if sshHealth != .disabled {
                proxyStatusRow(label: String(localized: "SSH Agent"), health: sshHealth)
            }
            if runHealth != .disabled {
                proxyStatusRow(label: String(localized: "Run Proxy"), health: runHealth)
            }
            if cliHealth.requiresAuthenticationRecovery {
                Button(cliHealth.loginActionTitle, action: onLoginPassCLI)
            }
            Divider()
            Button("Refresh Now", action: onRefresh)
                .keyboardShortcut("r", modifiers: .command)
            SettingsMenuCommand(onOpenSettings: onOpenSettings)
            Button("Quit", action: onQuit)
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var cliStatusRow: some View {
        let label = String(localized: "Pass CLI")
        let text: String
        let color: NSColor
        switch cliHealth {
        case .ok where recommendedVersionWarning != nil:
            text = String(localized: "\(label): update recommended")
            color = .systemOrange
        case .ok:
            text = String(localized: "\(label): Connected")
            color = .systemGreen
        case .notLoggedIn:
            text = String(localized: "\(label): not logged in")
            color = .systemOrange
        case .localSessionUnreadable:
            text = String(localized: "\(label): local session could not be decrypted")
            color = .systemRed
        case .notInstalled:
            text = String(localized: "\(label): not installed")
            color = .systemRed
        case .failed:
            text = String(localized: "\(label): error")
            color = .systemRed
        }
        return statusRow(text, color: color)
    }

    private func proxyStatusRow(label: String, health: ProxyHealthState) -> some View {
        let text: String
        let color: NSColor
        switch health {
        case .ok(let detail):
            let suffix = detail.map { " (\($0))" } ?? ""
            text = String(localized: "\(label): OK\(suffix)")
            color = .systemGreen
        case .degraded(let reason):
            text = String(localized: "\(label): \(reason.userFacingText)")
            color = .systemOrange
        case .unreachable(let reason):
            text = String(localized: "\(label): \(reason.userFacingText)")
            color = .systemRed
        case .disabled:
            text = ""
            color = .secondaryLabelColor
        }
        return statusRow(text, color: color)
    }

    private func statusRow(_ text: String, color: NSColor) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(nsImage: Self.coloredDot(color: color))
                .accessibilityHidden(true)
        }
        .disabled(true)
    }

    private static func coloredDot(color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
