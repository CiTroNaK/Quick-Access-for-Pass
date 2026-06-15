import SwiftUI

struct SecuritySettingsTab: View {
    @Binding var clipboardClearTimeout: Double
    @Binding var searchClearTimeout: Double
    @Binding var concealFromClipboardManagers: Bool
    @Binding var lockoutEnabled: Bool
    @Binding var lockoutTimeout: Double
    @Binding var lockOnSystemLock: Bool
    var onDisableLocking: () async -> Bool

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
            SettingsLayout.settingsRow(label: "Lock when Mac locks") {
                Toggle("", isOn: $lockOnSystemLock)
                    .toggleStyle(.switch)
                    .onChange(of: lockOnSystemLock) { oldValue, newValue in
                        Task {
                            await Self.restoreLockToggleIfDisableDenied(
                                oldValue: oldValue,
                                newValue: newValue,
                                setValue: { lockOnSystemLock = $0 },
                                authorize: onDisableLocking
                            )
                        }
                    }
            }
            SettingsLayout.settingsRow(label: "Lock after inactivity") {
                Toggle("", isOn: $lockoutEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: lockoutEnabled) { oldValue, newValue in
                        Task {
                            await Self.restoreLockToggleIfDisableDenied(
                                oldValue: oldValue,
                                newValue: newValue,
                                setValue: { lockoutEnabled = $0 },
                                authorize: onDisableLocking
                            )
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

    @MainActor
    static func restoreLockToggleIfDisableDenied(
        oldValue: Bool,
        newValue: Bool,
        setValue: (Bool) -> Void,
        authorize: () async -> Bool
    ) async {
        guard oldValue && !newValue else { return }

        let allowed = await authorize()
        if !allowed {
            setValue(true)
        }
    }
}
