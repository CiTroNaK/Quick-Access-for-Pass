#if QA_SETTINGS_UI_ACCEPTANCE
import SwiftUI
@testable import Quick_Access_for_Pass

/// Hosts only production proxy tabs or the actual indicator presentation; never General/SettingsRoot.
@MainActor
struct SettingsStatusIndicatorHostingView: View {
    @Bindable var fixture: SettingsStatusIndicatorHostingFixture

    var body: some View {
        Group {
            switch fixture.mode {
            case .tabs:
                TabView(selection: $fixture.selectedTab) {
                    SettingsProxyTabs(
                        selectedTab: fixture.selectedTab,
                        isSettingsWindowVisible: fixture.coordinator.isSettingsWindowVisible,
                        sshProxyEnabled: .constant(true),
                        sshUpstreamSocketPath: .constant(""),
                        runProxyEnabled: .constant(true)
                    )
                    Tab("Synthetic other tab", systemImage: "circle", value: SettingsTab.about) {
                        Text("Synthetic fixture — no services")
                    }
                }
            case .indicator:
                StatusIndicatorContent(state: fixture.state, animationsActive: fixture.animationsActive,
                                       reduceMotion: fixture.reduceMotion)
            }
        }
        .frame(width: 560, height: 650)
        .background {
            SettingsWindowObserver { fixture.coordinator.observeSettingsWindow($0) }
        }
        .onChange(of: fixture.coordinator.isSettingsWindowVisible) { _, _ in
            fixture.windowEligibilityDidChange()
        }
        .defaultAppStorage(fixture.defaults)
        .environment(fixture.health)
        .environment(\.databaseManager, nil)
        .environment(\.settingsPulseLifecycleObserver, fixture.observer)
    }
}
#endif
