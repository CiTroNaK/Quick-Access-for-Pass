import SwiftUI

/// Compatibility view for the terminal host section now presented in Integrations settings.
struct TerminalHostsSettingsView: View {
    let store: TerminalHostStore

    var body: some View {
        IntegrationsSettingsTab(store: store)
    }
}
