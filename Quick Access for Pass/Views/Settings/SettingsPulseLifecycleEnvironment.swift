import SwiftUI

extension EnvironmentValues {
    /// Optional host-local aura lifecycle observation; carries no status, identity, or secret content.
    @Entry var settingsPulseLifecycleObserver: SettingsPulseLifecycleObserver?
}
