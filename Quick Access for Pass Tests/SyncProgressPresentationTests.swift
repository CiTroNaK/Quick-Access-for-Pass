import Testing
@testable import Quick_Access_for_Pass

@Suite("Sync progress presentation")
struct SyncProgressPresentationTests {

    @Test("vault started shows vault name before item counts are known")
    func vaultStartedText() {
        #expect(SyncProgressPresentation.vaultStarted(vaultName: "Personal").statusText == "Syncing Personal…")
    }

    @Test("decoded items shows count and total")
    func itemCountText() {
        let progress = SyncProgressPresentation.itemsDecoded(
            vaultName: "Personal",
            completedItems: 10,
            totalItems: 400,
            skippedItems: 0
        )
        #expect(progress.statusText == "Syncing Personal 10/400 items")
    }

    @Test("decoded items includes skipped count")
    func skippedCountText() {
        let progress = SyncProgressPresentation.itemsDecoded(
            vaultName: "Work",
            completedItems: 398,
            totalItems: 400,
            skippedItems: 2
        )
        #expect(progress.statusText == "Syncing Work 398/400 items · 2 skipped")
    }

    @Test("completion with skipped items is explicit")
    func completedWithSkippedText() {
        #expect(SyncProgressPresentation.completedWithSkippedItems(3).statusText == "Synced with 3 skipped items")
    }
}
