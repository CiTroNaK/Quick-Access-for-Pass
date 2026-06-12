import SwiftUI

struct SettingsRoot: View {
    let appDelegate: AppDelegate

    var body: some View {
        SettingsView()
            .environment(appDelegate.healthStore)
            .environment(appDelegate.passCLIStatusStore)
            .environment(\.databaseManager, appDelegate.databaseManager)
            .task { @MainActor in
                await appDelegate.healthCoordinator?.refreshAll()
            }
    }
}
