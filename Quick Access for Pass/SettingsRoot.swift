import SwiftUI

struct SettingsRoot: View {
    let appDelegate: AppDelegate

    var body: some View {
        SettingsView(onWindowAvailable: { window in
            appDelegate.settingsWindowCoordinator.observeSettingsWindow(window)
        })
            .environment(appDelegate.healthStore)
            .environment(appDelegate.passCLIStatusStore)
            .environment(\.databaseManager, appDelegate.databaseManager)
            .environment(\.passCLIPATSettingsModel, appDelegate.passCLIPATSettingsModel)
            .task { @MainActor in
                await appDelegate.healthCoordinator?.refreshAll()
                await appDelegate.passCLIPATSettingsModel?.refreshSavedTokenState()
            }
    }
}
