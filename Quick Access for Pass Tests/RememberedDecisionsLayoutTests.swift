import AppKit
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("Remembered decisions layout", .serialized)
@MainActor
struct RememberedDecisionsLayoutTests {
    @Test("The decision viewport fills the sheet above Done", arguments: [1, 30])
    func viewportFillsSheet(rowCount: Int) throws {
        let viewport = NSView()
        let hosting = NSHostingView(rootView: RememberedDecisionsManagerView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remembered decisions")
                RememberedDecisionList(accessibilityLabel: "Remembered decisions") {
                    ForEach(0..<rowCount, id: \.self) { index in
                        Text("Decision \(index)").frame(height: 32)
                    }
                }
                .background(DecisionViewportProbe(view: viewport))
            }
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        #expect(hosting.bounds.size == NSSize(width: 720, height: 480))
        #expect(viewport.bounds.width == 680)
        #expect(viewport.bounds.height > 370,
                "The viewport must use the available sheet height, not the old 260-point inline height")
        let frame = viewport.convert(viewport.bounds, to: hosting)
        let bottomGap = hosting.isFlipped ? hosting.bounds.maxY - frame.maxY : frame.minY
        #expect(bottomGap < 70, "Only the Done footer and padding should remain beneath the list")
    }
}

private struct DecisionViewportProbe: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
