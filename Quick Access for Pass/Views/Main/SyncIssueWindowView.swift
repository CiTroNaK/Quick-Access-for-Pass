import SwiftUI

nonisolated enum SyncIssueWindowState: Equatable, Sendable {
    case empty
    case current(QuickAccessSyncIssuePresentation)
    case resolved(QuickAccessSyncIssuePresentation)

    var presentation: QuickAccessSyncIssuePresentation? {
        switch self {
        case .empty:
            nil
        case .current(let presentation), .resolved(let presentation):
            presentation
        }
    }

    var accessibilityAnnouncement: String {
        switch self {
        case .empty:
            Self.emptyTitle
        case .current(let presentation):
            presentation.title
        case .resolved:
            Self.resolvedTitle
        }
    }

    static var resolvedTitle: String {
        String(localized: "No current sync diagnostics", comment: "Resolved sync diagnostics window status.")
    }

    static var resolvedSymbolName: String {
        "info.circle.fill"
    }

    static var emptyTitle: String {
        String(localized: "No current sync errors", comment: "Empty sync diagnostics window status.")
    }
}

struct SyncIssueWindowView: View {
    nonisolated static let contentPadding: CGFloat = 20
    nonisolated static let contentFrameAlignment = Alignment.topLeading

    nonisolated static let resolvedSubtitle = String(
        localized: "The diagnostics below are from the previous issue shown in this window.",
        comment: "Resolved sync diagnostics window subtitle explaining archived diagnostics."
    )

    nonisolated static let previousDiagnosticDisclosureTitle = String(
        localized: "Previous diagnostic",
        comment: "Disclosure title for archived sync diagnostics after the current issue resolves."
    )

    let state: SyncIssueWindowState
    let copyReport: @MainActor @Sendable () -> Void
    let copyAndReport: @MainActor @Sendable () -> Void
    let copySkippedItemCommand: @MainActor @Sendable (SkippedSyncItem) -> Void
    let dismiss: @MainActor @Sendable () -> Void
    let close: @MainActor @Sendable () -> Void

    @State private var isPreviousDiagnosticExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .empty:
                emptyState
            case .current(let presentation):
                issueView(presentation)
            case .resolved(let presentation):
                resolvedState(presentation)
            }
        }
        .frame(
            minWidth: 520,
            idealWidth: 620,
            minHeight: 320,
            idealHeight: 420,
            alignment: Self.contentFrameAlignment
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.emptyTitle)
                .font(.headline)
            Text("The latest sync has no diagnostics to show.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close") { close() }
                    .appClearGlassButtonStyle()
            }
        }
        .padding(Self.contentPadding)
    }

    private func resolvedState(_ presentation: QuickAccessSyncIssuePresentation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            resolvedHeader
            DisclosureGroup(isExpanded: $isPreviousDiagnosticExpanded) {
                issueView(presentation, mode: .archived)
                    .padding(.top, 8)
            } label: {
                Text(Self.previousDiagnosticDisclosureTitle)
                    .font(.headline)
            }
        }
        .padding(Self.contentPadding)
    }

    private var resolvedHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: SyncIssueWindowState.resolvedSymbolName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.resolvedTitle)
                    .font(.headline)
                Text(Self.resolvedSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func issueView(
        _ presentation: QuickAccessSyncIssuePresentation,
        mode: QuickAccessSyncIssueViewMode = .current
    ) -> some View {
        QuickAccessSyncIssueView(
            presentation: presentation,
            mode: mode,
            performLogin: {},
            copyReport: copyReport,
            copyAndReport: copyAndReport,
            copySkippedItemCommand: copySkippedItemCommand,
            dismiss: dismiss
        )
    }
}

private extension SyncIssueWindowView {
    static var emptyTitle: String { SyncIssueWindowState.emptyTitle }
    static var resolvedTitle: String { SyncIssueWindowState.resolvedTitle }
}
