import SwiftUI

struct ItemRowView: View {
    let item: PassItem
    let isSelected: Bool
    let vaultName: String
    let folderLocation: FolderLocationPresentation?
    let folderFeatureGate: FolderFeatureGate?
    let folderFeatureStamp: FolderFeatureStamp?

    init(item: PassItem, isSelected: Bool, vaultName: String, folderLocation: FolderLocationPresentation? = nil,
         folderFeatureGate: FolderFeatureGate? = nil, folderFeatureStamp: FolderFeatureStamp? = nil) {
        self.item = item
        self.isSelected = isSelected
        self.vaultName = vaultName
        self.folderLocation = folderLocation
        self.folderFeatureGate = folderFeatureGate
        self.folderFeatureStamp = folderFeatureStamp
    }

    /// A cached row cannot reappear after a probe or executable change, even before observer delivery.
    var visibleFolderLocation: FolderLocationPresentation? {
        guard let folderLocation, !folderLocation.ancestorNames.isEmpty, !folderLocation.path.isEmpty,
              let folderFeatureGate, let folderFeatureStamp,
              folderFeatureGate.isCurrent(folderFeatureStamp) else { return nil }
        return folderLocation
    }

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
                            .layoutPriority(2)
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
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let location = visibleFolderLocation {
                        folderPill(location)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

    private func folderPill(_ location: FolderLocationPresentation) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "folder")
                .accessibilityHidden(true)
            Text(verbatim: location.path)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(.quaternary.opacity(0.3), in: Capsule())
        .frame(minWidth: 0, maxWidth: 180, alignment: .leading)
        .clipped()
        .layoutPriority(-1)
        .help(location.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: location.path))
    }

    private func shortDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host() else {
            return urlString
        }
        return host
    }
}
