import Foundation

struct DetailRowSelectionEntry: Sendable, Equatable {
    let id: DetailRow.ID
    let isSelectable: Bool
}

struct DetailSelectionState: Equatable {
    private(set) var selectedID: DetailRow.ID?
    private(set) var entries: [DetailRowSelectionEntry] = []
    private var isExplicitlyDeselected = false

    init(selectedID: DetailRow.ID? = nil) {
        self.selectedID = selectedID
    }

    mutating func select(_ id: DetailRow.ID?) {
        selectedID = id
        isExplicitlyDeselected = id == nil
    }

    mutating func reconcile(with entries: [DetailRowSelectionEntry]) {
        let current = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.isSelectable) })
        if let selectedID, current[selectedID] == true {
            self.entries = entries
            return
        }
        if selectedID == nil, isExplicitlyDeselected {
            self.entries = entries
            return
        }

        if let selectedID, let previousIndex = self.entries.firstIndex(where: { $0.id == selectedID }) {
            let previous = Array(self.entries.dropFirst(previousIndex + 1)) + Array(self.entries.prefix(previousIndex).reversed())
            self.selectedID = previous.first(where: { current[$0.id] == true })?.id
        } else {
            self.selectedID = nil
        }
        if self.selectedID == nil {
            self.selectedID = entries.first(where: \.isSelectable)?.id
        }
        isExplicitlyDeselected = false
        self.entries = entries
    }
}
