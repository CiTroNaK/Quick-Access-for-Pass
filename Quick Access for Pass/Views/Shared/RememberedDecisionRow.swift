import AppKit
import SwiftUI

nonisolated struct RememberedDecisionRowConfig: Sendable {
    let bundleID: String
    let primaryText: String
    let secondaryText: String
    let detailText: String?
    let allowed: Bool
    let removeHelpText: String

    init(
        bundleID: String,
        primaryText: String,
        secondaryText: String,
        detailText: String? = nil,
        allowed: Bool = true,
        removeHelpText: String
    ) {
        self.bundleID = bundleID
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.detailText = detailText
        self.allowed = allowed
        self.removeHelpText = removeHelpText
    }
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
                if let detailText = config.detailText {
                    Text(detailText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Image(systemName: config.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(config.allowed ? .green : .red)
                .accessibilityLabel(config.allowed ? String(localized: "Allowed") : String(localized: "Denied"))
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
