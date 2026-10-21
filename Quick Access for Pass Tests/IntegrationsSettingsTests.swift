import Foundation
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite @MainActor struct IntegrationsSettingsTests {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        lazy var defaults = UserDefaults(suiteName: suite)!
        var candidates: [URL] = []
        lazy var discovery = TerminalHostDiscovery(candidates: { self.candidates })
        lazy var store = TerminalHostStore(defaults: defaults, discovery: discovery)

        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func executable(_ name: String = "herdr") throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("inert fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func herdrIsAlwaysTheOnlySupportedProduct() {
        #expect(SupportedTerminalHost.allCases == [.herdr])
        #expect(SupportedTerminalHost.herdr.rawValue == "herdr")
        #expect(SupportedTerminalHost.herdr.displayName == "Herdr")
    }

    @Test func tabRawValuesRemainStableAndIntegrationsPrecedesAbout() {
        #expect(SettingsTab.general.rawValue == "general")
        #expect(SettingsTab.shortcuts.rawValue == "shortcuts")
        #expect(SettingsTab.security.rawValue == "security")
        #expect(SettingsTab.offline.rawValue == "offline")
        #expect(SettingsTab.passCLI.rawValue == "passCLI")
        #expect(SettingsTab.ssh.rawValue == "ssh")
        #expect(SettingsTab.run.rawValue == "run")
        #expect(SettingsTab.integrations.rawValue == "integrations")
        #expect(SettingsTab.allCases.suffix(2) == [.integrations, .about])
    }

    @Test func herdrAppearsWithoutDiscoveryAndStatesReflectAvailabilityAndOverride() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let empty = fixture.store
        #expect(SupportedTerminalHost.allCases.contains(.herdr))
        #expect(empty.entries.isEmpty)

        let installed = try fixture.executable()
        fixture.candidates = [installed]
        empty.refreshDetectedHosts()
        #expect(empty.entries.first?.id == "herdr")
        #expect(empty.availableIDs.contains("herdr"))

        let custom = try fixture.executable("custom-herdr")
        let herdr = TerminalHostConfiguration(id: "herdr", executablePath: custom.path, displayName: "Herdr",
                                               isEnabled: true, provider: .herdr, showPaneDetails: true,
                                               isAutomaticallyDetected: true)
        let generic = TerminalHostConfiguration(id: "mask", executablePath: custom.path, displayName: "Custom",
                                                 isEnabled: false, provider: .generic, showPaneDetails: false,
                                                 isAutomaticallyDetected: false)
        struct Envelope: Encodable { let version: Int; let entries: [TerminalHostConfiguration] }
        fixture.defaults.set(try JSONEncoder().encode(Envelope(version: 1, entries: [herdr, generic])),
                             forKey: DefaultsKey.terminalHosts)
        fixture.candidates = [custom]
        let collision = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(collision.hasCustomHerdrOverride)
        #expect(collision.entries.first(where: { $0.id == "herdr" })?.executablePath == custom.path)
        try FileManager.default.removeItem(at: custom)
        #expect(!collision.availableIDs.contains("herdr"))
    }

    @Test(arguments: [0, 1, 2]) func shortCustomListsFitWithoutTallScrollRegion(count: Int) throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        for index in 0..<count {
            try fixture.store.addExecutable(at: fixture.executable("terminal-\(index)"))
        }
        let view = NSHostingView(rootView: IntegrationsSettingsTab(store: fixture.store).frame(width: 560))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width <= 560)
        #expect(view.fittingSize.height <= 400)
    }

    @Test func longCustomListsStayWithinBoundedSettingsPaneHeight() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        for index in 0..<8 {
            try fixture.store.addExecutable(at: fixture.executable("long-terminal-\(index)"))
        }
        let view = NSHostingView(rootView: IntegrationsSettingsTab(store: fixture.store).frame(width: 560))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width <= 560)
        #expect(view.fittingSize.height <= 450,
                "Long custom-host lists must scroll instead of expanding the Settings pane")
    }

    @Test func homePathExpansionIsFilesystemOnlyAndPreservesSpaces() {
        let home = URL(fileURLWithPath: "/isolated fixture/home")
        let resolved = TerminalHostEditorModel.executableURL(from: " ~/bin/my terminal ", homeDirectory: home)
        #expect(resolved?.path == "/isolated fixture/home/bin/my terminal")
        #expect(TerminalHostEditorModel.executableURL(from: "$HOME/bin/tool", homeDirectory: home) == nil)
        #expect(TerminalHostEditorModel.executableURL(from: "../tool", homeDirectory: home) == nil)
    }
}
