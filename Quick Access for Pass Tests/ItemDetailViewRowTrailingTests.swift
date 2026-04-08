import Testing
@testable import Quick_Access_for_Pass
import AppKit

@Suite("ItemDetailView.RowTrailing mapping")
struct ItemDetailViewRowTrailingTests {

    @Test("namedAction .openURL maps to .openShortcut with the shortcut text")
    func openURLMapsToOpenShortcut() {
        let row = DetailRow.namedAction(action: .openURL, label: "Open in Browser", shortcut: "⌘O")
        #expect(ItemDetailView.rowTrailing(for: row) == .openShortcut("⌘O"))
    }

    @Test("namedAction non-open maps to .shortcut with the shortcut text")
    func nonOpenActionMapsToShortcut() {
        let row = DetailRow.namedAction(action: .copyPassword, label: "Copy Password", shortcut: "⌘P")
        #expect(ItemDetailView.rowTrailing(for: row) == .shortcut("⌘P"))
    }

    @Test("field row maps to .copyHint regardless of sensitivity")
    func fieldMapsToCopyHint() {
        let plain = DetailRow.field(key: .email, label: "Email", isSensitive: false)
        let hidden = DetailRow.field(key: .cardCVV, label: "CVV", isSensitive: true)
        #expect(ItemDetailView.rowTrailing(for: plain) == .copyHint)
        #expect(ItemDetailView.rowTrailing(for: hidden) == .copyHint)
    }

    @Test("sectionHeader maps to nil (not selectable, no trailing)")
    func sectionHeaderMapsToNil() {
        let row = DetailRow.sectionHeader(name: "Bank", id: "0:Bank")
        #expect(ItemDetailView.rowTrailing(for: row) == nil)
    }
}
