import AppKit
import Testing
@testable import Quick_Access_for_Pass

@Suite @MainActor
struct AuthorizationPanelSizingTests {
    private func panel(frame: NSRect = NSRect(x: 120, y: 300, width: 420, height: 220)) -> NSPanel {
        NSPanel(contentRect: frame, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    @Test func preservesWidthAndTopEdgeWhenGrowingAndShrinking() {
        let panel = panel()
        let original = panel.frame
        AuthorizationPanelSizing.resize(panel, contentHeight: 360)
        let grown = panel.frame
        #expect(grown.width == original.width)
        #expect(abs(grown.maxY - original.maxY) < 0.01)
        #expect(grown.height > original.height)
        AuthorizationPanelSizing.resize(panel, contentHeight: 140)
        let shrunk = panel.frame
        #expect(shrunk.width == original.width)
        #expect(abs(shrunk.maxY - original.maxY) < 0.01)
        #expect(shrunk.height < grown.height)
    }

    @Test func ignoresNoOpAndInvalidHeights() {
        let panel = panel()
        let initial = panel.frame
        AuthorizationPanelSizing.resize(panel, contentHeight: panel.contentView?.bounds.height ?? initial.height)
        #expect(panel.frame == initial)
        for invalid in [CGFloat.zero, -1, .infinity, -.infinity, .nan] {
            AuthorizationPanelSizing.resize(panel, contentHeight: invalid)
            #expect(panel.frame == initial)
        }
    }

    @Test func limitsRequestedSizeToScreenVisibleBounds() {
        let screen = NSScreen.main
        guard let screen else { return }
        let panel = panel(frame: NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20,
                                        width: 420, height: 180))
        AuthorizationPanelSizing.resize(panel, contentHeight: screen.visibleFrame.height * 3)
        #expect(panel.frame.height <= screen.visibleFrame.height + 1)
        #expect(panel.frame.minY >= screen.visibleFrame.minY - 1)
        #expect(panel.frame.maxY <= screen.visibleFrame.maxY + 1)
    }
}
