import SwiftUI

struct ItemRowView: View {
    let item: PassItem
    let isSelected: Bool
    let vaultName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.itemType.sfSymbol)
                .font(.subheadline)
                .foregroundStyle(item.itemType.tintColor)
                .frame(width: 28, height: 28)
                .appGlassEffect(cornerRadius: 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let url = item.url {
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(shortDomain(from: url))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(vaultName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.3), in: Capsule())
                }
            }

            Spacer(minLength: 4)

            if isSelected {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.tint.opacity(0.15))
                    .appGlassEffect(cornerRadius: 8)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func shortDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host() else {
            return urlString
        }
        return host
    }
}
