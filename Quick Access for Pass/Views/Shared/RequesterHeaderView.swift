import AppKit
import SwiftUI

struct RequesterHeaderView: View {
    let model: RequesterHeaderModel?
    let fallbackName: String
    let fallbackBundleURL: URL?
    let subtitle: LocalizedStringResource

    private var presentation: RequesterPresentation {
        model?.presentation ?? .init(name: fallbackName, bundleURL: fallbackBundleURL,
                                     symbolName: "questionmark.app", hostID: nil, details: nil)
    }

    private var appIcon: NSImage {
        if let url = presentation.bundleURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: nil)
            ?? NSImage(named: NSImage.applicationIconName)!
    }

    private var workspaceAndTab: String? {
        let labels = [presentation.details?.workspaceLabel, presentation.details?.tabLabel].compactMap { $0 }
        return labels.isEmpty ? nil : labels.joined(separator: " / ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if model?.reservesDetailRows == true {
                // Fixed one-line slots participate in initial sizeThatFits, even before enrichment.
                VStack(alignment: .leading, spacing: 2) {
                    detailRow(workspaceAndTab, symbol: "rectangle.stack", label: "Workspace and tab")
                    detailRow(presentation.details?.paneTitle, symbol: "terminal", label: "Pane title")
                    detailRow(presentation.details?.workingDirectory, symbol: "folder", label: "Working directory")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: model?.detailsEligible) { await model?.loadDetails() }
        .onDisappear { model?.cancel() }
    }

    private func detailRow(_ value: String?, symbol: String, label: LocalizedStringResource) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(value ?? " ")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 16, alignment: .leading)
        .opacity(value == nil ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value ?? ""))
        .accessibilityHidden(value == nil)
    }
}
