import SwiftUI
@preconcurrency import LocalAuthentication

private let defaultHotkeyCode = 49
private let defaultHotkeyModifiers = 655360
private let defaultShowLargeTypeKeyCode = 36
private let defaultShowLargeTypeModifiers = Int(NSEvent.ModifierFlags.shift.rawValue)

struct SettingsView: View {
    @AppStorage(DefaultsKey.clipboardClearTimeout) var clipboardClearTimeout: Double = 30
    @AppStorage(DefaultsKey.concealFromClipboardManagers) var concealFromClipboardManagers: Bool = true
    @AppStorage(DefaultsKey.searchClearTimeout) var searchClearTimeout: Double = 60
    @AppStorage(DefaultsKey.lastSyncTime) var lastSyncTime: Double = 0
    @AppStorage(DefaultsKey.syncInterval) var syncInterval: Double = 300
    @AppStorage(DefaultsKey.cliPath) var cliPath: String = ""
    @AppStorage(DefaultsKey.sshProxyEnabled) var sshProxyEnabled: Bool = false
    @AppStorage(DefaultsKey.sshUpstreamSocketPath) var sshUpstreamSocketPath: String = ""
    @AppStorage(DefaultsKey.runProxyEnabled) var runProxyEnabled: Bool = false
    @AppStorage(DefaultsKey.lockoutEnabled) var lockoutEnabled: Bool = false
    @AppStorage(DefaultsKey.lockoutTimeout) var lockoutTimeout: Double = LockoutTimeout.default.seconds
    @AppStorage(DefaultsKey.hotkeyCode) var hotkeyCode: Int = defaultHotkeyCode
    @AppStorage(DefaultsKey.hotkeyModifiers) var hotkeyModifiers: Int = defaultHotkeyModifiers
    @AppStorage(DefaultsKey.copyUsernameKeyCode) var copyUsernameKeyCode: Int = 8
    @AppStorage(DefaultsKey.copyUsernameModifiers) var copyUsernameModifiers: Int = 1048576
    @AppStorage(DefaultsKey.copyPasswordKeyCode) var copyPasswordKeyCode: Int = 8
    @AppStorage(DefaultsKey.copyPasswordModifiers) var copyPasswordModifiers: Int = 1179648
    @AppStorage(DefaultsKey.copyTotpKeyCode) var copyTotpKeyCode: Int = 8
    @AppStorage(DefaultsKey.copyTotpModifiers) var copyTotpModifiers: Int = 1572864
    @AppStorage(DefaultsKey.showLargeTypeKeyCode) var showLargeTypeKeyCode: Int = defaultShowLargeTypeKeyCode
    @AppStorage(DefaultsKey.showLargeTypeModifiers) var showLargeTypeModifiers: Int = defaultShowLargeTypeModifiers

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab(hotkeyCode: $hotkeyCode, hotkeyModifiers: $hotkeyModifiers)
            }
            Tab("Shortcuts", systemImage: "command") {
                ShortcutsSettingsTab(
                    copyUsernameKeyCode: $copyUsernameKeyCode,
                    copyUsernameModifiers: $copyUsernameModifiers,
                    copyPasswordKeyCode: $copyPasswordKeyCode,
                    copyPasswordModifiers: $copyPasswordModifiers,
                    copyTotpKeyCode: $copyTotpKeyCode,
                    copyTotpModifiers: $copyTotpModifiers,
                    showLargeTypeKeyCode: $showLargeTypeKeyCode,
                    showLargeTypeModifiers: $showLargeTypeModifiers
                )
            }
            Tab("Security", systemImage: "lock.shield") {
                SecuritySettingsTab(
                    clipboardClearTimeout: $clipboardClearTimeout,
                    searchClearTimeout: $searchClearTimeout,
                    concealFromClipboardManagers: $concealFromClipboardManagers,
                    lockoutEnabled: $lockoutEnabled,
                    lockoutTimeout: $lockoutTimeout,
                    onDisableLockout: {
                        let context = LAContext()
                        do {
                            try await context.evaluatePolicy(
                                .deviceOwnerAuthenticationWithBiometrics,
                                localizedReason: String(localized: "Authenticate to disable lock")
                            )
                            return true
                        } catch {
                            return false
                        }
                    }
                )
            }
            Tab("Pass CLI", systemImage: "terminal") {
                PassCLISettingsTab(
                    syncInterval: $syncInterval,
                    lastSyncTime: $lastSyncTime,
                    cliPath: $cliPath
                )
            }
            Tab("SSH", systemImage: "lock.shield.fill") {
                SSHSettingsTab(
                    sshProxyEnabled: $sshProxyEnabled,
                    sshUpstreamSocketPath: $sshUpstreamSocketPath
                )
            }
            Tab("Run", systemImage: "play.circle") {
                RunSettingsTab(runProxyEnabled: $runProxyEnabled)
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettingsTab()
            }
        }
        .frame(width: 480)
        .background {
            SettingsWindowTitleSetter()
        }
    }
}
