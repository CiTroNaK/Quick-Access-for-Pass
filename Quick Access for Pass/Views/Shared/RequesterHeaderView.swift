import AppKit
import SwiftUI

struct RequesterHeaderView: View {
    let model: RequesterHeaderModel?
    let fallbackName: String
    let fallbackBundleURL: URL?
    let subtitle: LocalizedStringResource
    var displayedCommand: String? = nil

    private var presentation: RequesterPresentation {
        model?.presentation ?? .init(name: fallbackName, bundleURL: fallbackBundleURL,
                                     symbolName: "questionmark.app", hostID: nil, details: nil)
    }

    private var contextRows: [RequesterHeaderContext.Row] {
        RequesterHeaderContext.rows(for: presentation, displayedCommand: displayedCommand)
    }

    private var appIcon: NSImage {
        if let url = presentation.bundleURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: nil)
            ?? NSImage(named: NSImage.applicationIconName)!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            if !contextRows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(contextRows.enumerated()), id: \.offset) { _, row in
                        detailRow(row)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: model?.detailsEligible) { await model?.loadDetails() }
        .onDisappear { model?.cancel() }
        .onChange(of: contextRows.isEmpty) { oldValue, newValue in
            guard oldValue != newValue else { return }
            AccessibilityNotification.Announcement(
                newValue ? String(localized: "Requester context unavailable") : String(localized: "Requester context available")
            ).post()
        }
    }

    private func detailRow(_ row: RequesterHeaderContext.Row) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol(for: row.kind)).accessibilityHidden(true)
            Text(row.value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel(for: row.kind)))
        .accessibilityValue(Text(row.value))
    }

    private func symbol(for kind: RequesterHeaderContext.Kind) -> String {
        switch kind {
        case .workspaceAndTab: "rectangle.stack"
        case .paneTitle: "terminal"
        case .workingDirectory: "folder"
        }
    }

    private func accessibilityLabel(for kind: RequesterHeaderContext.Kind) -> LocalizedStringResource {
        switch kind {
        case .workspaceAndTab: "Workspace and tab"
        case .paneTitle: "Pane title"
        case .workingDirectory: "Working directory"
        }
    }
}
