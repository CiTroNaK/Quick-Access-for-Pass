import SwiftUI

@main
struct QuickAccessPassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsRoot(appDelegate: appDelegate)
        }
    }
}
