import SwiftUI

/// Lists what the active Pass CLI version supports. Presentation only; features are enabled
/// by their own version gates, never by this summary.
struct PassCLIFeatureSupportView: View {
    let features: [PassCLIFeatureSupport]
    @Environment(\.locale) private var locale

    var body: some View {
        if features.isEmpty {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(features) { support in
                    row(for: support)
                }
            }
        }
    }

    private func row(for support: PassCLIFeatureSupport) -> some View {
        let title = Self.title(for: support.feature, locale: locale)
        let state = Self.statusText(for: support.status, locale: locale)
        let detail = Self.detail(for: support.status, locale: locale)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Label(state, systemImage: Self.symbol(for: support.status))
                .font(.caption2)
                .foregroundStyle(Self.tint(for: support.status))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Self.tint(for: support.status).opacity(0.15), in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [title, state, detail].compactMap(\.self).joined(separator: ", ")))
    }

    static func title(for feature: PassCLIFeature, locale: Locale) -> String {
        switch feature {
        case .folders:
            text(LocalizedStringResource("Folders", comment: "Pass CLI feature name in Settings."), locale: locale)
        case .fastOfflineSync:
            text(LocalizedStringResource("Fast offline sync", comment: """
                Pass CLI feature name in Settings: offline copies reuse the item list instead of fetching items one by one.
                """), locale: locale)
        case .vaultPasswordPolicy:
            text(LocalizedStringResource("Vault password policy", comment: """
                Pass CLI feature name in Settings: handling of shared vaults whose owner hides passwords.
                """), locale: locale)
        }
    }

    static func statusText(for status: PassCLIFeatureStatus, locale: Locale) -> String {
        switch status {
        case .supported:
            text(LocalizedStringResource("Supported", comment: "Pass CLI feature status pill: tested and available."),
                 locale: locale)
        case .untested:
            text(LocalizedStringResource("Untested", comment: """
                Pass CLI feature status pill: the CLI version should support the feature, but this release was not tested.
                """), locale: locale)
        case .unsupported, .unverifiedRelease:
            text(LocalizedStringResource("Unsupported", comment: "Pass CLI feature status pill: not available with this CLI version."),
                 locale: locale)
        }
    }

    static func detail(for status: PassCLIFeatureStatus, locale: Locale) -> String? {
        switch status {
        case .supported, .untested:
            nil
        case .unsupported(let minimum?):
            text(LocalizedStringResource("Needs \(minimum.description) or newer", comment: """
                Pass CLI feature detail. Placeholder is a Pass CLI version number such as 2.5.0.
                """), locale: locale)
        case .unsupported(nil):
            text(LocalizedStringResource("Disabled for this version", comment: """
                Pass CLI feature detail when the app turned a feature off for a known-bad CLI release.
                """), locale: locale)
        case .unverifiedRelease(let minimum):
            text(LocalizedStringResource("Not verified for this version · Use a tested release or \(minimum.description)+", comment: """
                Pass CLI feature detail for an untested older CLI release. Placeholder is a Pass CLI version number such as 2.5.0.
                """), locale: locale)
        }
    }

    private static func text(_ resource: LocalizedStringResource, locale: Locale) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    private static func symbol(for status: PassCLIFeatureStatus) -> String {
        switch status {
        case .supported: "checkmark.circle.fill"
        case .untested: "questionmark.circle.fill"
        case .unsupported, .unverifiedRelease: "xmark.circle.fill"
        }
    }

    private static func tint(for status: PassCLIFeatureStatus) -> Color {
        switch status {
        case .supported: .green
        case .untested: .orange
        case .unsupported, .unverifiedRelease: .secondary
        }
    }
}

#Preview("Untested CLI") {
    PassCLIFeatureSupportView(features: PassCLICapabilities(version: PassCLIVersion(major: 2, minor: 8, patch: 0)).featureSupport)
        .padding()
}
#Preview("Old CLI") {
    PassCLIFeatureSupportView(features: PassCLICapabilities(version: PassCLIVersion(major: 2, minor: 1, patch: 4)).featureSupport)
        .padding()
}
