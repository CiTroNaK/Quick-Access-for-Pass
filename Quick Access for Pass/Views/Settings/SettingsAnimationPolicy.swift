import SwiftUI

/// Admission policy for decorative work in a Settings tab.
nonisolated enum SettingsAnimationPolicy {
    static func isActive(isWindowVisible: Bool, selectedTab: SettingsTab, tab: SettingsTab) -> Bool {
        isWindowVisible && selectedTab == tab
    }
}

extension EnvironmentValues {
    /// Decorative Settings work is disabled outside an explicitly eligible tab.
    @Entry var settingsAnimationsActive = false
}
