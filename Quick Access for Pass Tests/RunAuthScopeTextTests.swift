import AppKit
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@MainActor
@Suite("Run authorization scope text layout")
struct RunAuthScopeTextTests {
    @Test("Scope text wraps instead of truncating under a compressed height proposal", arguments: [
        "Exact matches every argument. Broader scopes also match commands with different arguments.",
        "Přesný příkaz porovnává všechny argumenty. Širší rozsahy zahrnují i příkazy s jinými argumenty.",
        "Exact command: \"gh\" \"api\" \"repos/example/project/actions/runs/123456789/jobs\" \"--jq\" \".jobs[] | .name\""
    ])
    func scopeTextWrapsAtPromptWidth(text: String) {
        // Measure the actual scope-text component without starting authentication or a countdown.
        let hosting = NSHostingController(rootView: RunAuthScopeText(text: text).font(.caption2))
        let singleLine = hosting.sizeThatFits(in: CGSize(width: 2_000, height: 1))
        let promptWidth = hosting.sizeThatFits(in: CGSize(width: 340, height: 1))

        #expect(singleLine.height > 0)
        #expect(promptWidth.height > singleLine.height,
                "The 340-point content area must grow to show all text, not compress it to one truncated line")
        #expect(promptWidth.width <= 340, "Scope text must wrap within the panel rather than overflow horizontally")
    }
}
