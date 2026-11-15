import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite @MainActor struct HerdrCoreSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "HerdrCoreSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func switchesDefaultOnAndPersist() throws {
        try withDefaults { defaults in
            let settings = HerdrCoreSettings(defaults: defaults)
            #expect(settings.isEnabled)
            #expect(settings.showsDetails)
            settings.isEnabled = false
            settings.showsDetails = false
            let reloaded = HerdrCoreSettings(defaults: defaults)
            #expect(!reloaded.isEnabled)
            #expect(!reloaded.showsDetails)
        }
    }

    @Test func observersAreNotifiedUntilRemoved() throws {
        try withDefaults { defaults in
            let settings = HerdrCoreSettings(defaults: defaults)
            var notifications = 0
            let token = settings.observeChanges { notifications += 1 }
            settings.isEnabled = false
            settings.showsDetails = false
            settings.removeObserver(token)
            settings.isEnabled = true
            #expect(notifications == 2)
        }
    }

    @Test func installedLocationChecksCommandsThenBundleThenApp() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = URL(fileURLWithPath: "/Applications/Herdr Core.app")
        func locate(_ url: URL?) -> String? { HerdrCoreSettings.installedLocation(homeDirectory: home.path, locateApp: { url }) }
        func makeExecutable(_ relative: String) throws -> String {
            let file = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
        #expect(locate(nil) == nil)
        #expect(locate(app) == app.path)
        _ = try makeExecutable(".local/share/herdr-core/current/Contents/MacOS/herdr-core")
        #expect(locate(app) == home.appendingPathComponent(".local/share/herdr-core/current").path)
        let daemon = try makeExecutable(".local/bin/herdr-core")
        #expect(locate(app) == daemon)
        let command = try makeExecutable(".local/bin/hc")
        #expect(locate(app) == command)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: command)
        #expect(locate(app) == daemon)
    }
}
