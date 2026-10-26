import SwiftUI

struct QuickAccessResultsList: View {
    let items: [PassItem]
    let selectedIndex: Int
    let vaultName: (String) -> String
    let showDetailAtIndex: (Int) -> Void
    let folderLocation: (String) -> FolderLocationPresentation?
    let folderFeatureGate: FolderFeatureGate?
    let folderFeatureStamp: FolderFeatureStamp?

    init(items: [PassItem], selectedIndex: Int, vaultName: @escaping (String) -> String,
         showDetailAtIndex: @escaping (Int) -> Void,
         folderLocation: @escaping (String) -> FolderLocationPresentation? = { _ in nil },
         folderFeatureGate: FolderFeatureGate? = nil, folderFeatureStamp: FolderFeatureStamp? = nil) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.vaultName = vaultName
        self.showDetailAtIndex = showDetailAtIndex
        self.folderLocation = folderLocation
        self.folderFeatureGate = folderFeatureGate
        self.folderFeatureStamp = folderFeatureStamp
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        let currentIndex = items.firstIndex(where: { $0.id == item.id }) ?? index
                        showDetailAtIndex(currentIndex)
                    } label: {
                        ItemRowView(
                            item: item,
                            isSelected: items[safe: selectedIndex]?.id == item.id,
                            vaultName: vaultName(item.vaultId),
                            folderLocation: folderLocation(item.id),
                            folderFeatureGate: folderFeatureGate,
                            folderFeatureStamp: folderFeatureStamp
                        )
                    }
                    .buttonStyle(.plain)
                    .id(item.id)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 4)
            .onChange(of: selectedIndex) { _, newIndex in
                if let id = items[safe: newIndex]?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}
