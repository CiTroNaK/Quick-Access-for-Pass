import Foundation
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite @MainActor struct TerminalHostStoreTests {
    @MainActor private final class Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite = UUID().uuidString
        var candidates: [URL] = []

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
        }

        var discovery: TerminalHostDiscovery { TerminalHostDiscovery(candidates: { self.candidates }) }

        func executable(_ name: String = "herdr") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A deliberately non-runnable executable fixture: discovery must only inspect the filesystem.
            try Data("synthetic executable fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func save(_ entries: [TerminalHostConfiguration], version: Int = 1) throws {
            struct Envelope: Encodable { let version: Int; let entries: [TerminalHostConfiguration] }
            defaults.set(try JSONEncoder().encode(Envelope(version: version, entries: entries)), forKey: DefaultsKey.terminalHosts)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func generic(_ url: URL, enabled: Bool = true, id: String = "custom") -> TerminalHostConfiguration {
        .init(id: id, executablePath: url.path, displayName: "Custom terminal", isEnabled: enabled,
              provider: .generic, showPaneDetails: false, isAutomaticallyDetected: false)
    }

    @Test func matchingEntriesCarryCanonicalPathsAcrossSymlinkUpgradeAndCollision() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let target = try fixture.executable("real/herdr")
        let link = fixture.directory.appendingPathComponent("herdr")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        fixture.candidates = [link]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(store.matchingEntries.first?.configuration.executablePath == link.path)
        #expect(store.matchingEntries.first?.canonicalExecutablePath == target.path)
        let replacement = try fixture.executable("upgrade/herdr")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
        store.refreshDetectedHosts()
        #expect(store.matchingEntries.first?.canonicalExecutablePath == replacement.path)
        let custom = generic(replacement, enabled: false, id: "mask")
        try fixture.save(store.entries + [custom])
        let restarted = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(restarted.matchingEntries.isEmpty)
        #expect(restarted.entries.count == 2)
    }

    @Test func herdrIsAddedOnce() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        fixture.candidates = [try fixture.executable()]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        store.refreshDetectedHosts(); store.refreshDetectedHosts()
        #expect(store.entries.count == 1)
        let entry = try #require(store.entries.first)
        #expect(entry.id == "herdr")
        #expect(entry.displayName == "Herdr")
        #expect(entry.isEnabled && entry.showPaneDetails && entry.isAutomaticallyDetected)
        #expect(entry.provider == .herdr)
    }

    @Test func disableSurvivesRestartAndRediscovery() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        fixture.candidates = [try fixture.executable()]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        store.remove(id: "herdr")
        store.refreshDetectedHosts()
        let restarted = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(restarted.entries.count == 1)
        #expect(restarted.entries.first?.isEnabled == false)
    }

    @Test func editedNameSurvivesDiscovery() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        fixture.candidates = [try fixture.executable()]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        var entry = try #require(store.entries.first)
        entry.displayName = "My terminal"; entry.showPaneDetails = false
        try store.update(entry)
        store.refreshDetectedHosts()
        let restarted = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(restarted.entries == [entry])
    }

    @Test func upgradeUpdatesAutomaticPathWithoutResettingChoices() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        fixture.candidates = [try fixture.executable("old/herdr")]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        var entry = try #require(store.entries.first)
        entry.displayName = "Chosen name"; entry.isEnabled = false; entry.showPaneDetails = false
        try store.update(entry)
        let unrelated = try fixture.executable("unrelated")
        try store.addExecutable(at: unrelated)
        let custom = try #require(store.entries.last)
        fixture.candidates = [try fixture.executable("new/herdr")]
        store.refreshDetectedHosts()
        entry.executablePath = fixture.candidates[0].path
        #expect(store.entries == [entry, custom])
        let restarted = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(restarted.entries == [entry, custom])
    }

    @Test func missingInstallRetainsDisabledEntry() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        fixture.candidates = [try fixture.executable()]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        store.remove(id: "herdr")
        let saved = store.entries
        try FileManager.default.removeItem(at: fixture.candidates[0])
        let restarted = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(!restarted.configurationError)
        #expect(restarted.entries == saved)
        #expect(restarted.availableIDs.isEmpty)
    }

    @Test func unavailableEnabledEntryCanBeDisabledAndRenamedAfterRestart() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let url = try fixture.executable("custom")
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        try store.addExecutable(at: url)
        try FileManager.default.removeItem(at: url)
        let restarted = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        var entry = try #require(restarted.entries.first)
        entry.isEnabled = false; entry.displayName = "Unavailable terminal"
        try restarted.update(entry)
        #expect(restarted.entries == [entry])
        #expect(restarted.availableIDs.isEmpty)
        #expect(!restarted.configurationError)
        #expect(TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery).entries == [entry])
    }

    @Test(arguments: [true, false]) func genericMappingSuppressesAutomaticHerdr(enabled: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let url = try fixture.executable()
        let custom = generic(url, enabled: enabled)
        try fixture.save([custom])
        fixture.candidates = [url]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        store.refreshDetectedHosts(); store.observeExecutable(at: url)
        #expect(store.entries == [custom])
        #expect(store.effectiveEntries == (enabled ? [custom] : []))
        #expect(TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery).entries == [custom])
    }

    @Test(arguments: [true, false]) func genericSymlinkMappingSuppressesAncestryAndRestart(enabled: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let url = try fixture.executable("actual/herdr")
        let symlink = fixture.directory.appendingPathComponent("herdr")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
        let custom = generic(url, enabled: enabled)
        try fixture.save([custom])
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        store.observeExecutable(at: symlink)
        #expect(store.entries == [custom])
        #expect(store.effectiveEntries == (enabled ? [custom] : []))
        fixture.candidates = [symlink]
        #expect(TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery).entries == [custom])
    }

    @Test func observedAncestryDiscoversNonstandardHerdrWithoutExecuting() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let url = try fixture.executable("nonstandard/herdr")
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(store.entries.isEmpty)
        store.observeExecutable(at: try fixture.executable("herdr-helper"))
        #expect(store.entries.isEmpty)
        store.observeExecutable(at: url)
        #expect(store.entries.first?.executablePath == url.path)
        #expect(store.entries.first?.provider == .herdr)
        #expect(TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery).entries == store.entries)
    }

    @Test func customExecutableIsNotExecuted() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let marker = fixture.directory.appendingPathComponent("must-not-exist")
        let url = try fixture.executable("custom")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: url)
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        try store.addExecutable(at: url)
        store.observeExecutable(at: url); store.refreshDetectedHosts()
        #expect(store.entries.first?.provider == .generic)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func symlinkDuplicateIsRejected() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let url = try fixture.executable("custom")
        let symlink = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        try store.addExecutable(at: symlink)
        #expect(store.entries.first?.executablePath == symlink.path)
        #expect(throws: TerminalHostStore.StoreError.self) { try store.addExecutable(at: url) }
        #expect(store.entries.count == 1)
    }

    @Test func ordinaryEditsPreserveProviderAndAutomaticProvenance() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        try store.addExecutable(at: try fixture.executable("custom"))
        var edited = try #require(store.entries.first)
        edited.provider = .herdr; edited.isAutomaticallyDetected = true; edited.displayName = "Edited"
        try store.update(edited)
        #expect(store.entries.first?.provider == .generic)
        #expect(store.entries.first?.isAutomaticallyDetected == false)
        #expect(store.entries.first?.displayName == "Edited")
    }

    @Test func selectingNewPathRequiresAvailableUniqueExecutable() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        let first = try fixture.executable("one"), second = try fixture.executable("two")
        try store.addExecutable(at: first); try store.addExecutable(at: second)
        let saved = store.entries
        var edited = saved[0]
        edited.executablePath = fixture.directory.appendingPathComponent("missing").path
        #expect(throws: TerminalHostStore.StoreError.self) { try store.update(edited) }
        edited.executablePath = second.path
        #expect(throws: TerminalHostStore.StoreError.self) { try store.update(edited) }
        #expect(store.entries == saved)
    }

    @Test func invalidPreferencesDoNotOverwriteSavedBytes() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let raw = Data("not json".utf8)
        fixture.defaults.set(raw, forKey: DefaultsKey.terminalHosts)
        fixture.candidates = [try fixture.executable()]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        store.refreshDetectedHosts(); store.observeExecutable(at: fixture.candidates[0])
        #expect(store.configurationError)
        #expect(store.entries.isEmpty && store.effectiveEntries.isEmpty)
        #expect(throws: TerminalHostStore.StoreError.self) { try store.addExecutable(at: fixture.candidates[0]) }
        store.remove(id: "herdr")
        #expect(store.entries.isEmpty)
        #expect(fixture.defaults.data(forKey: DefaultsKey.terminalHosts) == raw)
        store.resetInvalidPreferences()
        #expect(!store.configurationError)
        #expect(store.entries.first?.id == "herdr")
        #expect(fixture.defaults.data(forKey: DefaultsKey.terminalHosts) != raw)
    }
    @Test(arguments: [true, false]) func upgradeCollisionPreservesAutomaticChoicesButMasksProvider(enabled: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let old = try fixture.executable("old/herdr"), new = try fixture.executable("new/herdr")
        fixture.candidates = [old]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        var automatic = try #require(store.entries.first)
        automatic.displayName = "My Herdr"; automatic.showPaneDetails = false
        try store.update(automatic)
        let custom = generic(new, enabled: enabled)
        try store.addExecutable(at: new)
        var added = try #require(store.entries.last)
        added.isEnabled = custom.isEnabled; added.displayName = custom.displayName
        try store.update(added)
        fixture.candidates = [new]
        store.refreshDetectedHosts()
        automatic.executablePath = new.path
        #expect(store.entries == [automatic, added])
        #expect(store.effectiveEntries == (enabled ? [added] : []))
        let restarted = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(restarted.entries == [automatic, added])
        #expect(restarted.effectiveEntries == (enabled ? [added] : []))
        restarted.remove(id: added.id)
        #expect(restarted.effectiveEntries == [automatic])
    }

    @Test func observedUpgradeCollisionWithDisabledSymlinkMappingMasksProvider() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let old = try fixture.executable("old/herdr"), new = try fixture.executable("new/herdr")
        let alias = fixture.directory.appendingPathComponent("herdr")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: new)
        fixture.candidates = [old]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        try store.addExecutable(at: new)
        var custom = try #require(store.entries.last)
        custom.isEnabled = false
        try store.update(custom)
        store.observeExecutable(at: alias)
        #expect(store.entries.first?.executablePath == alias.path)
        #expect(store.entries.first?.isEnabled == true)
        #expect(store.effectiveEntries.isEmpty)
        fixture.candidates = []
        #expect(TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery).effectiveEntries.isEmpty)
    }

    @Test func observersNotifyOnEffectiveChangesAndCanUnsubscribe() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        fixture.candidates = [try fixture.executable()]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        var notifications = 0
        let token = store.observeChanges { notifications += 1 }
        let initialRevision = store.revision
        store.refreshDetectedHosts()
        var entry = try #require(store.entries.first)
        try store.update(entry)
        store.remove(id: "missing")
        #expect(notifications == 0)
        entry.displayName = "Renamed"; try store.update(entry)
        entry.showPaneDetails = false; try store.update(entry)
        entry.isEnabled = false; try store.update(entry)
        #expect(notifications == 3)
        #expect(store.revision == initialRevision + 3)
        store.remove(id: "herdr")
        #expect(notifications == 3)
        store.removeObserver(token)
        entry.displayName = "Again"; try store.update(entry)
        #expect(notifications == 3)
    }

    @Test func refreshNotifiesAvailabilityAndCanonicalMatchingChangesWithoutRewritingPreferences() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let target = try fixture.executable("one"), other = try fixture.executable("two")
        let alias = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        try store.addExecutable(at: alias)
        let saved = fixture.defaults.data(forKey: DefaultsKey.terminalHosts)
        var notifications = 0
        _ = store.observeChanges { notifications += 1 }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        store.refreshDetectedHosts()
        #expect(notifications == 1)
        try FileManager.default.removeItem(at: other)
        store.refreshDetectedHosts()
        #expect(notifications == 2)
        #expect(store.availableIDs.isEmpty)
        #expect(fixture.defaults.data(forKey: DefaultsKey.terminalHosts) == saved)
    }

    @Test(arguments: ["version", "duplicate", "relative", "empty", "multiline", "provenance", "wrongType"])
    func invalidPreferenceStructureRequiresExplicitReset(kind: String) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        var entry = generic(fixture.directory.appendingPathComponent("missing"))
        switch kind {
        case "relative": entry.executablePath = "relative/path"
        case "empty": entry.displayName = " "
        case "multiline": entry.displayName = "One\u{2028}Two"
        case "provenance": entry.provider = .herdr
        default: break
        }
        if kind == "wrongType" {
            fixture.defaults.set("invalid type", forKey: DefaultsKey.terminalHosts)
        } else {
            try fixture.save(kind == "duplicate" ? [entry, entry] : [entry], version: kind == "version" ? 2 : 1)
        }
        let raw = fixture.defaults.object(forKey: DefaultsKey.terminalHosts) as? NSObject
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(store.configurationError)
        #expect(store.entries.isEmpty && store.effectiveEntries.isEmpty)
        #expect(throws: TerminalHostStore.StoreError.self) { try store.update(entry) }
        #expect((fixture.defaults.object(forKey: DefaultsKey.terminalHosts) as? NSObject) == raw)
        var notifications = 0
        _ = store.observeChanges { notifications += 1 }
        store.resetInvalidPreferences()
        #expect(!store.configurationError)
        #expect(notifications == 1)
        let restarted = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(!restarted.configurationError && restarted.entries.isEmpty)
    }

    @Test func onlyExecutableRegularFilesCanBeSelectedOrDiscovered() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let plainFile = try fixture.executable("not-executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plainFile.path)
        let directory = fixture.directory.appendingPathComponent("herdr")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixture.candidates = [directory, plainFile]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        #expect(store.entries.isEmpty)
        #expect(throws: TerminalHostStore.StoreError.self) { try store.addExecutable(at: directory) }
        #expect(throws: TerminalHostStore.StoreError.self) { try store.addExecutable(at: plainFile) }
        #expect(store.entries.isEmpty)
    }

    @Test func automaticEditsCannotChangeProviderOrDiscoveryProvenance() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        fixture.candidates = [try fixture.executable()]
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        var edited = try #require(store.entries.first)
        edited.provider = .generic; edited.isAutomaticallyDetected = false; edited.displayName = "Edited"
        try store.update(edited)
        #expect(store.entries.first?.provider == .herdr)
        #expect(store.entries.first?.isAutomaticallyDetected == true)
        #expect(store.entries.first?.displayName == "Edited")
    }

    @Test func observersCanRemoveTheirTokenDuringNotification() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        var notifications = 0
        var token: UUID?
        token = store.observeChanges { [weak store] in
            notifications += 1
            if let token { store?.removeObserver(token) }
        }
        try store.addExecutable(at: try fixture.executable("one"))
        try store.addExecutable(at: try fixture.executable("two"))
        #expect(notifications == 1)
    }

    @Test(arguments: [false, true]) func generalSettingsFitsExistingWidthWithLongSyntheticMappings(invalidPreferences: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        for index in 0..<5 {
            let url = try fixture.executable("long-installation-directory-\(index)/terminal")
            try store.addExecutable(at: url)
            var entry = try #require(store.entries.last)
            entry.displayName = String(repeating: "Synthetic terminal name ", count: 8)
            try store.update(entry)
        }
        // Offscreen layout only: no window, app installation, launch, or executable invocation.
        if invalidPreferences {
            fixture.defaults.set(Data("invalid synthetic preferences".utf8), forKey: DefaultsKey.terminalHosts)
        }
        let displayedStore = invalidPreferences ? TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery) : store
        let view = NSHostingView(rootView: IntegrationsSettingsTab(store: displayedStore).frame(width: 560))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 500)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width <= 560)
        #expect(view.fittingSize.height <= 500)
    }

    @Test func namedAdditionValidatesAtomicallyAndNotifiesOnce() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: fixture.discovery)
        let url = try fixture.executable("terminal with spaces")
        var notifications = 0
        let token = store.observeChanges { notifications += 1 }
        defer { store.removeObserver(token) }
        let originalDefaults = fixture.defaults.object(forKey: DefaultsKey.terminalHosts) as? Data

        for invalidName in ["", "  ", "two\nlines"] {
            #expect(throws: TerminalHostStore.StoreError.invalidEntry) {
                try store.addExecutable(at: url, displayName: invalidName)
            }
            #expect(store.entries.isEmpty)
            #expect((fixture.defaults.object(forKey: DefaultsKey.terminalHosts) as? Data) == originalDefaults)
            #expect(notifications == 0)
        }
        #expect(throws: TerminalHostStore.StoreError.invalidExecutable) {
            try store.addExecutable(at: fixture.directory, displayName: "Directory")
        }
        #expect(throws: TerminalHostStore.StoreError.invalidExecutable) {
            try store.addExecutable(at: URL(fileURLWithPath: "relative/path"), displayName: "Relative")
        }
        #expect(notifications == 0)
        try store.addExecutable(at: url, displayName: "Named terminal")
        #expect(store.entries.first?.displayName == "Named terminal")
        #expect(notifications == 1)
        #expect(throws: TerminalHostStore.StoreError.duplicateExecutable) {
            try store.addExecutable(at: url, displayName: "Duplicate")
        }
        #expect(notifications == 1)
    }

}
