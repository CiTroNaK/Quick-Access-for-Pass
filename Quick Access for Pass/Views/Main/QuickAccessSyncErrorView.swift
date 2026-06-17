import SwiftUI

struct QuickAccessSyncErrorView: View {
    let presentation: SyncErrorPresentation
    let performAction: @MainActor @Sendable (SyncErrorAction) -> Void
    @State private var showsHelp = false
    @FocusState private var isHelpFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(presentation.visibleMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(presentation.action.title) {
                performAction(presentation.action)
            }
            .font(.caption)
            .appClearGlassButtonStyle()

            if presentation.action == .copyAndReport {
                Button {
                    showsHelp.toggle()
                } label: {
                    Label(SyncErrorPresentation.copyAndReportHelpAccessibilityLabel, systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .focused($isHelpFocused)
                .onChange(of: isHelpFocused) { _, isFocused in
                    showsHelp = isFocused
                }
                .help(SyncErrorPresentation.copyAndReportHelpText)
                .popover(isPresented: $showsHelp) {
                    Text(SyncErrorPresentation.copyAndReportHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}
