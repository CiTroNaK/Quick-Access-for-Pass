import SwiftUI

/// Shared production proxy tabs and their decorative-work admission, independent of unrelated settings/services.
struct SettingsProxyTabs: TabContent {
    let selectedTab: SettingsTab
    let isSettingsWindowVisible: Bool
    @Binding var sshProxyEnabled: Bool
    @Binding var sshUpstreamSocketPath: String
    @Binding var runProxyEnabled: Bool

    var body: some TabContent<SettingsTab> {
        Tab("SSH", systemImage: "lock.shield.fill", value: SettingsTab.ssh) {
            SSHSettingsTab(sshProxyEnabled: $sshProxyEnabled, sshUpstreamSocketPath: $sshUpstreamSocketPath)
                .environment(\.settingsAnimationsActive, SettingsAnimationPolicy.isActive(
                    isWindowVisible: isSettingsWindowVisible, selectedTab: selectedTab, tab: .ssh
                ))
        }
        Tab("Run", systemImage: "play.circle", value: SettingsTab.run) {
            RunSettingsTab(runProxyEnabled: $runProxyEnabled)
                .environment(\.settingsAnimationsActive, SettingsAnimationPolicy.isActive(
                    isWindowVisible: isSettingsWindowVisible, selectedTab: selectedTab, tab: .run
                ))
        }
    }
}
