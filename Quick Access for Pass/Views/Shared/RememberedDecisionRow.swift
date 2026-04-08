import AppKit
import SwiftUI

nonisolated struct RememberedDecisionRowConfig: Sendable {
    let bundleID: String
    let primaryText: String
    let secondaryText: String
    let removeHelpText: String
}

struct RememberedDecisionRow: View {
    let config: RememberedDecisionRowConfig
    let onDelete: () -> Void

    @State private var cachedIcon: Image?

    var body: some View {
        HStack(spacing: 6) {
            (cachedIcon ?? Image(systemName: "questionmark.app"))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.primaryText)
                    .font(.callout)
                Text(config.secondaryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Remove", systemImage: "minus.circle.fill", action: onDelete)
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .help(Text(config.removeHelpText))
        }
        .task(id: config.bundleID) {
            cachedIcon = await Self.loadIcon(forBundleID: config.bundleID)
        }
    }

    private static func loadIcon(forBundleID bundleID: String) async -> Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(systemName: "questionmark.app")
    }
}
