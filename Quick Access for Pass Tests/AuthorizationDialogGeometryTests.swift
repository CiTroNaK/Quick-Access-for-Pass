import AppKit
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AuthorizationDialogGeometryTests {
    @Test(arguments: [false, true])
    func attachedDialogGeometryGrowsForLateMetadataAndShrinksWhenCleared(isRun: Bool) async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = fixture.model()
        let screenFrame = try #require(NSScreen.main?.visibleFrame)
        let panel = NSPanel(
            contentRect: NSRect(x: screenFrame.minX + 80, y: screenFrame.minY + 280, width: 380, height: 260),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        defer {
            panel.contentView = nil
            model.cancel()
        }
        let measurements = DialogGeometryMeasurements()
        let authorizer = FakeBiometricAuthorizer(outcome: .success(()))
        let hosted: NSHostingController<AnyView>
        if isRun {
            let request = RunAuthRequest(
                appName: "Fixture terminal", appBundleURL: nil, headerModel: model,
                profileName: "Fixture", command: "git fetch", scopeOptions: [.prefix("git fetch")],
                keychainService: authorizer, callbacks: .noop,
                onContentHeightChange: { height in
                    measurements.values.append(height)
                    AuthorizationPanelSizing.resize(panel, contentHeight: height)
                },
                onResult: { _, _, _ in }
            )
            let dialog = RunAuthDialogView(request: request)
            hosted = NSHostingController(rootView: AnyView(dialog.geometryContent))
        } else {
            let request = SSHAuthRequest(
                appName: "Fixture terminal", appBundleURL: nil, headerModel: model,
                keyName: "Fixture key", triggerCommand: "git fetch", showCommand: true,
                host: "fixture.invalid", keychainService: authorizer, callbacks: .noop,
                onContentHeightChange: { height in
                    measurements.values.append(height)
                    AuthorizationPanelSizing.resize(panel, contentHeight: height)
                },
                onResult: { _, _ in }
            )
            let dialog = SSHAuthDialogView(request: request)
            hosted = NSHostingController(rootView: AnyView(dialog.geometryContent))
        }

        panel.contentView = hosted.view
        hosted.view.frame = NSRect(origin: .zero, size: NSSize(width: 380, height: 260))
        layout(hosted, in: panel)
        await fixture.provider.started()
        #expect(panel.frame.height.isFinite)
        let initialHeight = panel.frame.height
        #expect(initialHeight > 0 && initialHeight < screenFrame.height)

        await fixture.provider.finish()
        for _ in 0..<20 {
            await Task.yield()
            layout(hosted, in: panel)
            if model.presentation.details != nil { break }
        }
        #expect(model.presentation.details == RequesterHeaderFixture.details)
        let expandedHeight = panel.frame.height
        #expect(expandedHeight > initialHeight)
        #expect(measurements.values.contains { $0.isFinite && $0 > initialHeight })

        var entry = try #require(fixture.store.entries.first)
        entry.showPaneDetails = false
        try fixture.store.update(entry)
        #expect(model.presentation.details == nil)
        for _ in 0..<20 {
            await Task.yield()
            layout(hosted, in: panel)
            if panel.frame.height < expandedHeight { break }
        }
        #expect(panel.frame.height < expandedHeight)
        #expect(measurements.values.allSatisfy { $0.isFinite })

    }

    private func layout(_ hosting: NSHostingController<AnyView>, in panel: NSPanel) {
        for _ in 0..<3 {
            hosting.view.layoutSubtreeIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.layoutIfNeeded()
        }
    }
}

@MainActor
private final class DialogGeometryMeasurements {
    var values: [CGFloat] = []
}
