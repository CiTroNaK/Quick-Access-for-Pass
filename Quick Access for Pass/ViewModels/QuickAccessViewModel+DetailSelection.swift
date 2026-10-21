import Foundation

@MainActor
extension QuickAccessViewModel {
    var detailRowSelectionEntries: [DetailRowSelectionEntry] {
        guard let item = detailItem else { return [] }
        return entries(for: item)
    }

    func entries(for item: PassItem) -> [DetailRowSelectionEntry] {
        rows(for: item).map { DetailRowSelectionEntry(id: $0.id, isSelectable: isDetailRowSelectable($0, for: item)) }
    }

    func selectedDetailRow(for item: PassItem?) -> DetailRow? {
        guard let item else { return nil }
        let entries = entries(for: item)
        var state = detailSelectionState
        state.reconcile(with: entries)
        guard let id = state.selectedID else { return nil }
        return rows(for: item).first(where: { $0.id == id })
    }

    func reconcileDetailSelection(for item: PassItem) {
        detailSelectionState.reconcile(with: entries(for: item))
    }

    func selectDetailRow(at index: Int) {
        guard let item = detailItem else { detailSelectionState.select(nil); return }
        reconcileDetailSelection(for: item)
        let currentRows = rows(for: item)
        guard currentRows.indices.contains(index) else { return }
        selectDetailRow(id: currentRows[index].id)
    }

    func selectDetailRow(id: DetailRow.ID) {
        guard let item = detailItem else { detailSelectionState.select(nil); return }
        reconcileDetailSelection(for: item)
        guard let row = rows(for: item).first(where: { $0.id == id }),
              isDetailRowSelectable(row, for: item) else { return }
        detailSelectionState.select(id)
        reconcileDetailSelection(for: item)
    }

    func resetDetailSelection() {
        guard let item = detailItem else {
            detailSelectionState = DetailSelectionState()
            return
        }
        detailSelectionState = DetailSelectionState()
        reconcileDetailSelection(for: item)
    }
}
