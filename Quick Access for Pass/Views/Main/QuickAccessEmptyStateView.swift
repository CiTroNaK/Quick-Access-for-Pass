import SwiftUI

struct QuickAccessEmptyStateView: View {
    let message: String
    let secondaryMessage: String?
    let systemImage: String?

    var body: some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                    .accessibilityHidden(true)
            }
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let secondaryMessage {
                Text(secondaryMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}
