import SwiftUI

struct SSHSettingsTab: View {
    @Binding var sshProxyEnabled: Bool
    @Binding var sshUpstreamSocketPath: String
    @Environment(ProxyHealthStore.self) private var healthStore
    @Environment(\.databaseManager) private var databaseManager

    var body: some View {
        VStack(spacing: 0) {
            SettingsLayout.settingsPane {
            SettingsLayout.settingsRow(label: "Enable SSH proxy") {
                Toggle("", isOn: $sshProxyEnabled)
                    .toggleStyle(.switch)
            }
            SettingsLayout.settingsRow(label: "Proxy socket") {
                HStack(spacing: 4) {
                    Text(SSHAgentConstants.defaultProxySocketPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            NSString(string: SSHAgentConstants.defaultProxySocketPath).expandingTildeInPath,
                            forType: .string
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Copy proxy socket path"))
                }
            }
            SettingsLayout.settingsRow(label: "Upstream socket") {
                TextField(
                    SSHAgentConstants.defaultUpstreamSocketPath,
                    text: $sshUpstreamSocketPath
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            }

            Divider()

            SSHVaultFilterView()

            Divider()

            SSHShowCommandAppsView()

            Divider()

            if let databaseManager {
                SSHBatchModeDecisionsView(databaseManager: databaseManager)

                Divider()

                SSHAuthDecisionsView(databaseManager: databaseManager)

                Divider()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Add to ~/.ssh/config:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 4) {
                    Text(verbatim: "Host *\n\tIdentityAgent \"\(SSHAgentConstants.defaultProxySocketPath)\"")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        let expanded = NSString(string: SSHAgentConstants.defaultProxySocketPath).expandingTildeInPath
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "Host *\n\tIdentityAgent \"\(expanded)\"",
                            forType: .string
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Copy SSH config snippet"))
                }
            }

            }
            SSHStatusRow(state: healthStore.sshHealth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
