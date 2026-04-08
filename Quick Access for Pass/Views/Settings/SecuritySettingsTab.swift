import SwiftUI

struct SecuritySettingsTab: View {
    @Binding var clipboardClearTimeout: Double
    @Binding var searchClearTimeout: Double
    @Binding var concealFromClipboardManagers: Bool
    @Binding var lockoutEnabled: Bool
    @Binding var lockoutTimeout: Double
    var onDisableLockout: () async -> Bool

    var body: some View {
        SettingsLayout.settingsPane {
            SettingsLayout.settingsRow(label: "Auto-clear clipboard") {
                HStack(spacing: 4) {
                    TextField("", value: $clipboardClearTimeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                    Text("sec")
                        .foregroundStyle(.secondary)
                }
            }
            SettingsLayout.settingsRow(label: "Clear search on close") {
                HStack(spacing: 4) {
                    TextField("", value: $searchClearTimeout, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                    Text("sec")
                        .foregroundStyle(.secondary)
                    Text("(0 = never)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            SettingsLayout.settingsRow(label: "Conceal from clipboard managers") {
                Toggle("", isOn: $concealFromClipboardManagers)
                    .toggleStyle(.switch)
            }
            SettingsLayout.settingsRow(label: "Lock after inactivity") {
                Toggle("", isOn: $lockoutEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: lockoutEnabled) { oldValue, newValue in
                        if oldValue && !newValue {
                            Task {
                                let allowed = await onDisableLockout()
                                if !allowed {
                                    lockoutEnabled = true
                                }
                            }
                        }
                    }
            }
            if lockoutEnabled {
                SettingsLayout.settingsRow(label: "Lock after") {
                    Picker("", selection: $lockoutTimeout) {
                        ForEach(LockoutTimeout.allCases) { timeout in
                            Text(timeout.localizedLabel).tag(timeout.seconds)
                        }
                    }
                    .frame(width: 140)
                }
            }
        }
    }
}
