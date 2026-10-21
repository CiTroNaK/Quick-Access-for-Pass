import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite @MainActor struct TerminalHostEditorModelTests {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        lazy var defaults = UserDefaults(suiteName: suite)!
        var discovered: [URL] = []
        var store: TerminalHostStore { TerminalHostStore(defaults: defaults, discovery: TerminalHostDiscovery(candidates: { self.discovered })) }

        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func executable(_ name: String) throws -> URL {
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

    @Test func addsNamedPastedPathContainingSpacesAndTrimsInput() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let url = try fixture.executable("terminal app")
        let store = fixture.store
        let model = TerminalHostEditorModel(store: store)
        model.displayName = "  My terminal  "
        model.executablePath = "  \(url.path)  "
        #expect(model.save())
        #expect(store.entries.first?.displayName == "My terminal")
        #expect(store.entries.first?.executablePath == url.path)
    }

    @Test func expandsHomePathAndRejectsRelativeAndShellInput() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store
        let model = TerminalHostEditorModel(store: store)
        model.displayName = "Terminal"
        #expect(TerminalHostEditorModel.executableURL(from: " ~/bin/terminal ", homeDirectory: fixture.root)
            == fixture.root.appendingPathComponent("bin/terminal"))
        model.executablePath = fixture.root.appendingPathComponent("missing/bin/terminal").path
        #expect(!model.save())
        #expect(model.errorMessage != nil)
        model.executablePath = "relative/terminal"
        #expect(!model.save())
        model.executablePath = "$HOME/bin/terminal"
        #expect(!model.save())
        #expect(store.entries.isEmpty)
    }

    @Test func invalidInputLeavesPreferencesAndObserversUnchanged() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store
        let original = fixture.defaults.object(forKey: DefaultsKey.terminalHosts)
        var calls = 0
        let token = store.observeChanges { calls += 1 }
        defer { store.removeObserver(token) }
        let model = TerminalHostEditorModel(store: store)
        model.displayName = "\n"
        model.executablePath = "/not-used"
        #expect(!model.save())
        #expect(store.entries.isEmpty)
        #expect(fixture.defaults.object(forKey: DefaultsKey.terminalHosts) as? Data == original as? Data)
        #expect(calls == 0)
    }

    @Test func cancellingUnsavedEditorLeavesStoreAndPreferencesUnchanged() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let store = fixture.store
        let original = fixture.defaults.object(forKey: DefaultsKey.terminalHosts) as? Data
        let model = TerminalHostEditorModel(store: store)
        model.displayName = "Unsaved"
        model.executablePath = "/not/saved"
        // Cancel dismisses the sheet without invoking save().
        #expect(store.entries.isEmpty)
        #expect(fixture.defaults.object(forKey: DefaultsKey.terminalHosts) as? Data == original)
    }

    @Test func unavailableCustomPathCanBeRenamedWithoutChangingPath() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let url = try fixture.executable("terminal")
        let store = fixture.store
        try store.addExecutable(at: url, displayName: "Before")
        try FileManager.default.removeItem(at: url)
        let model = TerminalHostEditorModel(store: store, entryID: try #require(store.entries.first?.id))
        model.displayName = "After"
        #expect(model.save())
        #expect(store.entries.first?.displayName == "After")
        #expect(store.entries.first?.executablePath == url.path)
    }

    @Test func deletedEditTargetIsNotRecreated() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let url = try fixture.executable("terminal")
        let store = fixture.store
        try store.addExecutable(at: url)
        let id = try #require(store.entries.first?.id)
        let model = TerminalHostEditorModel(store: store, entryID: id)
        store.remove(id: id)
        model.displayName = "Renamed"
        #expect(!model.save())
        #expect(store.entries.isEmpty)
    }

    @Test func supportedRenameReloadsLatestPathAndPreservesConsent() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try fixture.executable("herdr")
        fixture.discovered = [original]
        let store = fixture.store
        let model = TerminalHostEditorModel(store: store, entryID: "herdr")
        var current = try #require(store.entries.first)
        current.isEnabled = false
        current.showPaneDetails = false
        try store.update(current)
        let newPath = try fixture.executable("upgrade/herdr")
        fixture.discovered = [newPath]
        store.refreshDetectedHosts()
        model.displayName = "Herdr renamed"
        #expect(model.save())
        let updated = try #require(store.entries.first)
        #expect(updated.displayName == "Herdr renamed")
        #expect(updated.executablePath == newPath.path)
        #expect(!updated.isEnabled && !updated.showPaneDetails)
        #expect(updated.provider == .herdr && updated.isAutomaticallyDetected)
    }
}
