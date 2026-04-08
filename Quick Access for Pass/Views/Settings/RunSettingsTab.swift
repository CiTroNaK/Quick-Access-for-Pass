import SwiftUI

struct RunSettingsTab: View {
    @Binding var runProxyEnabled: Bool
    @Environment(ProxyHealthStore.self) private var healthStore
    @Environment(\.databaseManager) private var databaseManager

    var body: some View {
        VStack(spacing: 0) {
            SettingsLayout.settingsPane {
            SettingsLayout.settingsRow(label: "Enable run proxy") {
                Toggle("", isOn: $runProxyEnabled)
                    .toggleStyle(.switch)
            }
            SettingsLayout.settingsRow(label: "Proxy socket") {
                HStack(spacing: 4) {
                    Text(DefaultsKey.runProxySocketPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            NSString(string: DefaultsKey.runProxySocketPath).expandingTildeInPath,
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

            Divider()

            if let databaseManager {
                RunProfilesSettingsView(databaseManager: databaseManager)

                Divider()

                RunAuthDecisionsView(databaseManager: databaseManager)

                Divider()
            }

            let qaRunPath = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/qa-run").path
            if FileManager.default.fileExists(atPath: qaRunPath) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add to ~/.zshrc for easy access:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 4) {
                        Text(verbatim: "alias qa-run='\(qaRunPath)'")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("alias qa-run='\(qaRunPath)'", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Copy qa-run alias"))
                    }
                }
            }

            }
            RunStatusRow(state: healthStore.runHealth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
