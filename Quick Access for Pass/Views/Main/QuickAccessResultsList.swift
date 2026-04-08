import SwiftUI

struct QuickAccessResultsList: View {
    let items: [PassItem]
    let selectedIndex: Int
    let vaultName: (String) -> String
    let showDetailAtIndex: (Int) -> Void

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
                            vaultName: vaultName(item.vaultId)
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
