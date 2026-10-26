import AppKit
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("Bounded native offline folder manager", .timeLimit(.minutes(1)))
@MainActor
struct OfflineFolderManagerRenderingTests {
    @Test func managerHeightAndScrollViewportStayBounded() async throws {
        let fixture = try await OfflineFolderManagerFixture()
        for language in ["en", "cs"] {
            for count in [0, 1, 40, 1300] {
                fixture.present(OfflineFolderManagerFixture.rows(count: count, longNames: true))
                try assertManagerLayout(fixture.coordinator, language: language, expectScrolling: count > 1, expectList: count > 0)
            }
        }
        #expect(await fixture.viewCallCount("item") == 0)
        #expect(try await fixture.folders.repository.offlineItemSelections().isEmpty)
        await fixture.service.stop()
    }

    @Test func retainedPolicyListStaysBoundedWithCapabilityAndObservationWarnings() async throws {
        let fixture = try await OfflineFolderManagerFixture(observationFails: true)
        #expect(fixture.coordinator.observationErrorMessage != nil)
        for language in ["en", "cs"] {
            for version in [nil, "2.4.2", "unknown"] as [String?] {
                fixture.present(OfflineFolderManagerFixture.rows(count: 40, longNames: true, selected: true))
                let probe = fixture.folders.gate.beginProbe()
                if let version { fixture.folders.gate.confirm(capabilities: .init(rawVersionString: version), for: probe) }
                #expect(fixture.coordinator.folderPresentationAvailability != .supported)
                try assertManagerLayout(fixture.coordinator, language: language, expectScrolling: true)
            }
        }
        #expect(await fixture.viewCallCount("item") == 0)
        #expect(try await fixture.folders.repository.offlineItemSelections().isEmpty)
        await fixture.service.stop()
    }

    @Test func deepPolicyPathsRemainInsideTheNativeViewport() async throws {
        let fixture = try await OfflineFolderManagerFixture()
        let deep = OfflineFolderSettingsRow(vaultID: "vault", folderID: "leaf", folderName: "Leaf",
            location: .init(folderID: "leaf", ancestorNames: Array(repeating: "Literal / ancestor", count: 63) + ["Leaf"]),
            isSelected: true, coveringAncestorID: nil, selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
        for language in ["en", "cs"] {
            for version in ["2.5.1", "2.4.2"] {
                let probe = fixture.folders.gate.beginProbe()
                fixture.folders.gate.confirm(capabilities: .init(rawVersionString: version), for: probe)
                fixture.present([deep])
                try assertManagerLayout(fixture.coordinator, language: language, expectScrolling: false)
            }
        }
        #expect(await fixture.viewCallCount("item") == 0)
        await fixture.service.stop()
    }

    private func assertManagerLayout(_ coordinator: OfflineModeCoordinator, language: String,
                                     expectScrolling: Bool, expectList: Bool = true) throws {
        let host = NSHostingView(rootView: OfflineFoldersManagerView(coordinator: coordinator, initialVaultID: "vault")
            .environment(\.locale, Locale(identifier: language)))
        #expect(host.fittingSize.width == 720)
        #expect(host.fittingSize.height == 480)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.update()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let views = OfflineFolderManagerFixture.descendants(of: host)
        guard expectList else {
            #expect(views.compactMap { $0 as? NSScrollView }.isEmpty)
            return
        }
        let scroll = try #require(views.compactMap { $0 as? NSScrollView }.first)
        let viewport = host.convert(scroll.bounds, from: scroll)
        #expect(host.bounds.contains(viewport))
        #expect(viewport.height > 0)
        #expect((scroll.documentView?.frame.width ?? 0) <= scroll.contentView.bounds.width + 1)
        // Preserve the footer region outside the scrolling list, in either native coordinate orientation.
        let footerSpace = host.isFlipped ? host.bounds.maxY - viewport.maxY : viewport.minY - host.bounds.minY
        #expect(footerSpace >= 40)
        if expectScrolling {
            #expect((scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height)
        }
    }

    @Test func nativeFilterDoesNotSelectItemsAndMissingVaultDisablesIt() async throws {
        let fixture = try await OfflineFolderManagerFixture()
        fixture.present(OfflineFolderManagerFixture.rows(count: 40))
        let host = NSHostingView(rootView: OfflineFoldersManagerView(coordinator: fixture.coordinator, initialVaultID: "vault")
            .environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let field = try #require(OfflineFolderManagerFixture.descendants(of: host)
            .compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.stringValue = "No match / %{literal}"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.layoutSubtreeIfNeeded()
        #expect(OfflineFolderManagerFixture.descendants(of: host).compactMap { $0 as? NSScrollView }.isEmpty)
        field.stringValue = ""
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.layoutSubtreeIfNeeded()
        #expect(!OfflineFolderManagerFixture.descendants(of: host).compactMap { $0 as? NSScrollView }.isEmpty)
        fixture.present(OfflineFolderManagerFixture.rows(count: 1), vaultID: "different-vault")
        host.layoutSubtreeIfNeeded()
        #expect(!field.isEnabled)
        #expect(OfflineFolderManagerFixture.descendants(of: host).compactMap { $0 as? NSScrollView }.isEmpty)
        #expect(await fixture.viewCallCount("item") == 0)
        #expect(try await fixture.folders.repository.offlineItemSelections().isEmpty)
        await fixture.service.stop()
    }

    @Test func settingsHeightDoesNotGrowWithFolderCount() async throws {
        let fixture = try await OfflineFolderManagerFixture()
        func height(_ count: Int) -> CGFloat {
            fixture.present(OfflineFolderManagerFixture.rows(count: count))
            let host = NSHostingView(rootView: OfflineSettingsTab()
                .environment(\.offlineModeCoordinator, fixture.coordinator).frame(width: 560))
            return host.fittingSize.height
        }
        let one = height(1)
        let forty = height(40)
        #expect(one > 0)
        #expect(abs(forty - one) <= 1, "40 folders must not grow Settings: \(one) → \(forty)")
        #expect(abs(height(1300) - one) <= 1)
        #expect(await fixture.viewCallCount("item") == 0)
        #expect(try await fixture.folders.repository.offlineItemSelections().isEmpty)
        await fixture.service.stop()
    }
}
