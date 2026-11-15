import SwiftUI

/// Compatibility view for the terminal host section now presented in Integrations settings.
struct TerminalHostsSettingsView: View {
    let store: TerminalHostStore
    let coreSettings: HerdrCoreSettings

    var body: some View {
        IntegrationsSettingsTab(store: store, coreSettings: coreSettings)
    }
}
