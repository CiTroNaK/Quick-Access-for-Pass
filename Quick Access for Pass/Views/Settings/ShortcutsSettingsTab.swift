import SwiftUI

struct ShortcutsSettingsTab: View {
    @Binding var copyUsernameKeyCode: Int
    @Binding var copyUsernameModifiers: Int
    @Binding var copyPasswordKeyCode: Int
    @Binding var copyPasswordModifiers: Int
    @Binding var copyTotpKeyCode: Int
    @Binding var copyTotpModifiers: Int
    @Binding var showLargeTypeKeyCode: Int
    @Binding var showLargeTypeModifiers: Int

    var body: some View {
        SettingsLayout.settingsPane {
            SettingsLayout.settingsRow(label: "Copy Username") {
                ShortcutRecorderView(keyCode: $copyUsernameKeyCode, modifiers: $copyUsernameModifiers)
                    .frame(width: 140)
            }
            SettingsLayout.settingsRow(label: "Copy Password") {
                ShortcutRecorderView(keyCode: $copyPasswordKeyCode, modifiers: $copyPasswordModifiers)
                    .frame(width: 140)
            }
            SettingsLayout.settingsRow(label: "Copy TOTP") {
                ShortcutRecorderView(keyCode: $copyTotpKeyCode, modifiers: $copyTotpModifiers)
                    .frame(width: 140)
            }
            SettingsLayout.settingsRow(label: "Show in Large Type") {
                ShortcutRecorderView(keyCode: $showLargeTypeKeyCode, modifiers: $showLargeTypeModifiers)
                    .frame(width: 140)
            }
        }
    }
}
