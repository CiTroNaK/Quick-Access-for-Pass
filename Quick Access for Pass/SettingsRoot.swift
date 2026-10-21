import SwiftUI

struct SettingsRoot: View {
    let appDelegate: AppDelegate
    @State private var autoFillAppAssociationsSettingsModel: AutoFillAppAssociationsSettingsModel?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        _autoFillAppAssociationsSettingsModel = State(
            initialValue: appDelegate.databaseManager.map {
                AutoFillAppAssociationsSettingsModel(
                    store: AutoFillAppAssociationStore(databaseManager: $0)
                )
            }
        )
    }

    var body: some View {
        SettingsView(
            onWindowAvailable: { window in
                appDelegate.settingsWindowCoordinator.observeSettingsWindow(window)
            },
            autoFillAppAssociationsSettingsModel: autoFillAppAssociationsSettingsModel,
            terminalHostStore: appDelegate.terminalHostStore
        )
            .onChange(of: appDelegate.databaseManager != nil) { _, databaseIsAvailable in
                guard databaseIsAvailable,
                      autoFillAppAssociationsSettingsModel == nil,
                      let databaseManager = appDelegate.databaseManager else {
                    return
                }
                autoFillAppAssociationsSettingsModel = AutoFillAppAssociationsSettingsModel(
                    store: AutoFillAppAssociationStore(databaseManager: databaseManager)
                )
            }
            .environment(appDelegate.healthStore)
            .environment(appDelegate.passCLIStatusStore)
            .environment(\.databaseManager, appDelegate.databaseManager)
            .environment(\.passCLIPATSettingsModel, appDelegate.passCLIPATSettingsModel)
            .environment(\.offlineModeCoordinator, appDelegate.offlineModeCoordinator)
            .task { @MainActor in
                await appDelegate.healthCoordinator?.refreshAll()
                await appDelegate.passCLIPATSettingsModel?.refreshSavedTokenState()
            }
    }
}
