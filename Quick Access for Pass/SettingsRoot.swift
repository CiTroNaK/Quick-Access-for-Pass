import SwiftUI

struct SettingsRoot: View {
    let appDelegate: AppDelegate

    var body: some View {
        SettingsView()
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
