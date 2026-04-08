import SwiftUI
import ServiceManagement

struct GeneralSettingsTab: View {
    @Binding var hotkeyCode: Int
    @Binding var hotkeyModifiers: Int

    @State private var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var selectedLanguage: String = {
        if let override = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
           let first = override.first {
            return String(first.prefix(2))
        }
        return "system"
    }()

    var body: some View {
        SettingsLayout.settingsPane {
            SettingsLayout.settingsRow(label: "Launch at Login") {
                Toggle("", isOn: $launchAtLoginEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLoginEnabled = !newValue
                        }
                    }
            }
            SettingsLayout.settingsRow(label: "Open Quick Access") {
                ShortcutRecorderView(keyCode: $hotkeyCode, modifiers: $hotkeyModifiers)
                    .frame(width: 140)
            }
            SettingsLayout.settingsRow(label: "Language") {
                Picker("", selection: $selectedLanguage) {
                    Text("System").tag("system")
                    Text("English").tag("en")
                    Text("Čeština").tag("cs")
                }
                .frame(width: 140)
                .onChange(of: selectedLanguage) { _, newValue in
                    if newValue == "system" {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    }
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Restart Required")
                    alert.informativeText = String(localized: "The app needs to restart for the language change to take effect.")
                    alert.addButton(withTitle: String(localized: "Restart Now"))
                    alert.addButton(withTitle: String(localized: "Later"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        let url = Bundle.main.bundleURL
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        task.arguments = ["-n", url.path]
                        try? task.run()
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}
