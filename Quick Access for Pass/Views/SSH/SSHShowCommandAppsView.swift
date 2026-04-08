import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SSHShowCommandAppsView: View {
    @AppStorage(DefaultsKey.sshShowCommandApps) private var appsJSON: String = "[]"

    private var apps: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(appsJSON.utf8))) ?? []
    }

    private func save(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list) {
            appsJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Show command for apps")
                .foregroundStyle(.secondary)
            Text("Commands are always shown for terminals. Add other apps here.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            ForEach(apps, id: \.self) { bundleID in
                HStack(spacing: 6) {
                    appIcon(for: bundleID)
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(appName(for: bundleID))
                        .font(.callout)
                    Text(bundleID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        save(apps.filter { $0 != bundleID })
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Remove application"))
                }
            }

            Button("Add Application…") {
                pickApplication()
            }
            .font(.caption)
        }
    }

    private func pickApplication() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Application")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        guard !apps.contains(bundleID) else { return }
        save(apps + [bundleID])
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let bundle = Bundle(url: url)
        return bundle?.infoDictionary?["CFBundleName"] as? String
            ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func appIcon(for bundleID: String) -> Image {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return Image(systemName: "app")
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}
