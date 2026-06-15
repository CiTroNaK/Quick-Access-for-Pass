import SwiftUI

struct PassCLISettingsTab: View {
    @Binding var syncInterval: Double
    @Binding var lastSyncTime: Double
    @Binding var cliPath: String
    @Environment(PassCLIStatusStore.self) private var statusStore
    @Environment(\.passCLIPATSettingsModel) private var patSettingsModel
    @State private var patInput = ""
    @State private var isReplacingPAT = false

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
                SettingsLayout.settingsRow(label: "CLI source") {
                    Text(cliSourceText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                SettingsLayout.settingsRow {
                    Text(cliSourceHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if case .notLoggedIn = statusStore.health {
                    SettingsLayout.settingsRow {
                        Button("Log In to Proton Pass CLI…") {
                            NotificationCenter.default.post(name: .passCLILoginRequested, object: nil)
                        }
                        .accessibilityHint("Starts Proton Pass CLI login and opens the Proton authentication page in your browser")
                    }
                }
                SettingsLayout.settingsRow(label: "Personal access token") {
                    personalAccessTokenControls
                }
                SettingsLayout.settingsRow(label: "Version") {
                    Text(statusStore.version ?? "—")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let tokenName = statusStore.identity?.personalAccessTokenName {
                    SettingsLayout.settingsRow(label: "Token name") {
                        Text(tokenName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(tokenName)
                    }
                } else {
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
        .task {
            await patSettingsModel?.refreshSavedTokenState()
        }
        .onDisappear {
            patInput = ""
            isReplacingPAT = false
        }
    }

    private var cliSourceText: String {
        switch statusStore.selection {
        case .custom(let path):
            "Custom: \(path)"
        case .system(let path):
            "System: \(path)"
        case .bundled(_, let architecture):
            if let version = statusStore.version {
                "Bundled: pass-cli \(version) (\(architecture.rawValue))"
            } else {
                "Bundled: pass-cli (\(architecture.rawValue))"
            }
        case .unresolved:
            "Not found"
        }
    }

    private var cliSourceHelpText: String {
        switch statusStore.selection {
        case .custom:
            "Clear this field to use auto-detection and bundled fallback. No fallback is attempted while a custom path is set."
        case .system:
            "Using your installed Proton Pass CLI. Clear or change the path field to alter discovery."
        case .bundled:
            "Included with Quick Access for Pass. Updates with the app."
        case .unresolved:
            "Install Proton Pass CLI or leave the path empty to use the bundled fallback in signed releases."
        }
    }

    @ViewBuilder
    private var personalAccessTokenControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let patSettingsModel {
                if patSettingsModel.hasSavedToken && !isReplacingPAT {
                    Text("Saved in Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Replace…") {
                            isReplacingPAT = true
                            patInput = ""
                        }
                        Button("Log In with Saved Token") {
                            Task { await patSettingsModel.loginUsingSavedToken() }
                        }
                        .disabled(patSettingsModel.isLoggingIn)
                        Button("Remove", role: .destructive) {
                            Task { await patSettingsModel.removeToken() }
                        }
                        .disabled(patSettingsModel.isLoggingIn)
                    }
                } else {
                    SecureField("Personal access token", text: $patInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .accessibilityHint("Paste a Proton Pass personal access token. The token is stored in Keychain.")
                    HStack {
                        if patSettingsModel.hasSavedToken {
                            Button("Cancel") {
                                isReplacingPAT = false
                                patInput = ""
                            }
                        }
                        Button(patSettingsModel.hasSavedToken ? "Replace & Log In" : "Save & Log In") {
                            let token = patInput
                            patInput = ""
                            isReplacingPAT = false
                            Task { await patSettingsModel.saveAndLogin(token: token) }
                        }
                        .disabled(patSettingsModel.isLoggingIn || patInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                PATSettingsMessage(
                    "Quick Access stores the token in Keychain and uses it to recreate lost pass-cli sessions. "
                        + "Token expiration is managed in Proton Pass and cannot be discovered or extended here."
                )

                if patSettingsModel.isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Logging in with personal access token")
                }
                if let statusMessage = patSettingsModel.statusMessage {
                    PATSettingsMessage(statusMessage, color: .green)
                }
                if let errorMessage = patSettingsModel.errorMessage {
                    PATSettingsMessage(errorMessage, color: .red)
                }
            } else {
                PATSettingsMessage("Personal access token settings are loading.")
            }
        }
    }
}

private struct PATSettingsMessage: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .lineLimit(nil)
            .frame(width: 300, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}
