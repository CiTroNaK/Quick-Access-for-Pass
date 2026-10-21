#if QA_SETTINGS_UI_ACCEPTANCE
import AppKit
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("Isolated Settings aura lifetime", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SettingsStatusIndicatorHostingTests {
    @Test func actualAuraIsRemovedAndRecreatedForLiveMotionAndHealthChanges() async throws {
        let fixture = try SettingsStatusIndicatorHostingFixture(mode: .indicator)
        defer { fixture.clean() }
        fixture.show()
        try await fixture.waitForLifecycle(appearances: 1, disappearances: 0)
        fixture.reduceMotion = true
        try await fixture.waitForLifecycle(appearances: 1, disappearances: 1)
        try assertStaticBaseRenders()
        fixture.reduceMotion = false
        try await fixture.waitForLifecycle(appearances: 2, disappearances: 1)
        fixture.animationsActive = false
        try await fixture.waitForLifecycle(appearances: 2, disappearances: 2)
        fixture.animationsActive = true
        try await fixture.waitForLifecycle(appearances: 3, disappearances: 2)
        fixture.state = .disabled
        try await fixture.waitForLifecycle(appearances: 3, disappearances: 3)
        fixture.state = .degraded(.cooldown)
        try await fixture.waitForLifecycle(appearances: 4, disappearances: 3)
        #expect(fixture.appearances == 4)
        #expect(fixture.disappearances == 3)
    }

    @Test func productionTabsRemoveAuraOnExitMinimizeAndCloseThenReopen() async throws {
        let fixture = try SettingsStatusIndicatorHostingFixture(mode: .tabs)
        defer { fixture.clean() }
        fixture.show()
        try await fixture.waitForLifecycle(appearances: 1, disappearances: 0)
        fixture.selectedTab = .about
        try await fixture.waitForLifecycle(appearances: 1, disappearances: 1)
        fixture.selectedTab = .ssh
        try await fixture.waitForLifecycle(appearances: 2, disappearances: 1)
        fixture.selectedTab = .run
        try await fixture.waitForLifecycle(appearances: 3, disappearances: 2)
        fixture.window.miniaturize(nil)
        try await fixture.waitForLifecycle(appearances: 3, disappearances: 3, visibility: false)
        fixture.window.deminiaturize(nil)
        try await fixture.waitForLifecycle(appearances: 4, disappearances: 3)
        fixture.window.close()
        try await fixture.waitForLifecycle(appearances: 4, disappearances: 4, visibility: false)
        fixture.show()
        let reopened = try await fixture.waitForLifecycle(appearances: 5, disappearances: 4)
        #expect(reopened.appearances == 5)
        #expect(reopened.disappearances == 4)
        fixture.window.close()
        let closed = try await fixture.waitForLifecycle(appearances: 5, disappearances: 5, visibility: false)
        #expect(!closed.windowEligible)
        #expect(reopened.windowEligible, "The matched observation must remain valid after a later real close")
    }

    @Test func fullyOccludingOnlyTheSyntheticWindowRemovesTheAura() async throws {
        let fixture = try SettingsStatusIndicatorHostingFixture(mode: .tabs)
        defer { fixture.clean() }
        fixture.show()
        try await fixture.waitForLifecycle(appearances: 1, disappearances: 0)
        let cover = NSWindow(contentRect: fixture.window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.isOpaque = true
        cover.backgroundColor = .white
        cover.hasShadow = false
        defer { cover.close() }
        cover.level = fixture.window.level
        cover.orderFrontRegardless()
        let occluded = try await fixture.waitForLifecycle(appearances: 1, disappearances: 1, visibility: false)
        #expect(!occluded.windowEligible)
        cover.orderOut(nil)
        let exposed = try await fixture.waitForLifecycle(appearances: 2, disappearances: 1)
        #expect(exposed.windowEligible)
        #expect(exposed.appearances - exposed.disappearances == 1)
    }

    private func assertStaticBaseRenders() throws {
        for state in [ProxyHealthState.ok(), .degraded(.emptyIdentities), .unreachable(.probeFailed), .disabled] {
            let renderer = ImageRenderer(content: StatusIndicatorContent(state: state, animationsActive: true, reduceMotion: true))
            let image = try #require(renderer.cgImage)
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            #expect(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }, "Base status remains when aura is absent")
        }
    }
}
#endif
