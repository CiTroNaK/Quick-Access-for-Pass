import SwiftUI

struct PassCLISettingsTab: View {
    @Binding var syncInterval: Double
    @Binding var lastSyncTime: Double
    @Binding var cliPath: String
    @Environment(PassCLIStatusStore.self) private var statusStore

    var body: some View {
        VStack(spacing: 0) {
            SettingsLayout.settingsPane {
                SettingsLayout.settingsRow(label: "Refresh every") {
                    HStack(spacing: 4) {
                        TextField("", value: $syncInterval, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text("sec")
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsLayout.settingsRow(label: "Last synced") {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(FormatHelpers.formatSyncTime(lastSyncTime, relativeTo: context.date))
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsLayout.settingsRow(label: "pass-cli path") {
                    TextField("auto-detect", text: $cliPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                if case .notInstalled = statusStore.health {
                    SettingsLayout.settingsRow {
                        Text("Install instruction at https://protonpass.github.io/pass-cli/ or set a custom path above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                SettingsLayout.settingsRow(label: "Version") {
                    Text(statusStore.version ?? "—")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsLayout.settingsRow(label: "Username") {
                    Text(statusStore.identity?.username ?? "—")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsLayout.settingsRow(label: "Email") {
                    Text(statusStore.identity?.email ?? "—")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsLayout.settingsRow(label: "Release track") {
                    Text(statusStore.identity?.releaseTrack ?? "—")
                        .foregroundStyle(.secondary)
                }
                SettingsLayout.settingsRow {
                    Button("Reset Cache & Sync") {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Reset local cache?")
                        alert.informativeText = String(
                            localized: "All locally cached items will be deleted and re-fetched from Proton Pass. Usage counts will be reset."
                        )
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: String(localized: "Reset & Sync"))
                        alert.addButton(withTitle: String(localized: "Cancel"))
                        if alert.runModal() == .alertFirstButtonReturn {
                            NotificationCenter.default.post(name: .resetDatabaseRequested, object: nil)
                        }
                    }
                    .foregroundStyle(.red)
                }
            }
            PassCLIStatusRow(health: statusStore.health, identity: statusStore.identity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
