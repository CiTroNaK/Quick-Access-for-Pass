import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("ItemDetailView — Offline rows")
struct ItemDetailViewOfflineTests {
    @Test func focusAndScrollTargetFollowSelectedIdentityAfterRowIndexShift() {
        let email = DetailRow.field(key: .email, label: "Email", isSensitive: false)
        let note = DetailRow.field(key: .noteBody, label: "Note", isSensitive: false)
        let inserted = DetailRow.keepOfflineIndividually
        let selectedID = note.id
        #expect(ItemDetailView.selectionTarget(selectedID: selectedID, rows: [email, inserted, note]) == selectedID)
        #expect(ItemDetailView.selectionTarget(selectedID: selectedID, rows: [email, note]) == selectedID)
        #expect(ItemDetailView.selectionTarget(selectedID: nil, rows: [email, note]) == nil)
    }

    @Test func offlineAvailabilityRowHasNoTrailingCopyHint() {
        #expect(ItemDetailView.rowTrailing(for: .offlineAvailability(.notCached)) == .offlineAction)
    }

    @Test func keepOfflineRowIsDistinctAndHasNoLargeTypeValue() {
        let row = DetailRow.keepOfflineIndividually
        #expect(row.id == "keepOfflineIndividually")
        #expect(row.isSelectable)
        #expect(ItemDetailView.rowTrailing(for: row) == .offlineAction)
        #expect(ItemDetailView.keepOfflineLabel == "Keep offline individually")
    }

    @Test func staleOfflineSnapshotOffersRemovalAndStatusText() {
        #expect(ItemDetailView.offlineLabel(for: .stale(lastRefreshedAt: .distantPast)) == "Remove offline copy")
        #expect(ItemDetailView.offlineIcon(for: .stale(lastRefreshedAt: .distantPast)) == "trash")
        #expect(ItemDetailView.offlineStatusText(for: .stale(lastRefreshedAt: .distantPast)) == "Stale")
        #expect(ItemDetailView.offlineStatusText(for: .available(lastRefreshedAt: .distantPast)) == "Cached")
    }
}
