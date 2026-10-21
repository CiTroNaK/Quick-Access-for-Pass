import SwiftUI

/// Uses the current menu's scene action; shared with the isolated cold-opening acceptance host.
struct SettingsMenuCommand: View {
    let onOpenSettings: (OpenSettingsAction) -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") { onOpenSettings(openSettings) }
            .keyboardShortcut(",", modifiers: .command)
    }
}
