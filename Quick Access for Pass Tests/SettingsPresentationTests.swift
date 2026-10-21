import AppKit
import Testing
@testable import Quick_Access_for_Pass

@Suite("Shared Settings presentation")
@MainActor
struct SettingsPresentationTests {
    @Test func preparationPrecedesSceneActionWithoutPanelOrUnlock() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.app.isForceLocked = true
        fixture.app.presentSettings {
            #expect(fixture.activations == 1)
            #expect(fixture.app.panelController == nil)
            #expect(fixture.app.isLocked)
            #expect(fixture.app.cliService == nil)
            #expect(fixture.app.healthCoordinator == nil)
            fixture.opens += 1
        }
        #expect(fixture.opens == 1)
        #expect(fixture.app.lastAuthenticatedAt == nil)
    }

    @Test func repeatedPresentationWithoutNewTargetRetainsDeferredFocus() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let previous = NSRunningApplication.current
        var restored: [pid_t] = []
        fixture.app.settingsWindowCoordinator = SettingsWindowCoordinator(
            isCurrentApplicationActive: { true },
            activateApplication: { restored.append($0.processIdentifier) }
        )
        fixture.app.presentSettings(using: { fixture.opens += 1 }, restoring: previous)
        fixture.app.presentSettings { fixture.opens += 1 }
        #expect(restored.isEmpty)
        fixture.app.settingsWindowCoordinator.settingsWindowWillClose()
        fixture.app.settingsWindowCoordinator.settingsWindowWillClose()
        #expect(restored == [previous.processIdentifier])
        #expect(fixture.opens == 2)
    }

    @MainActor
    private final class Fixture {
        let suite = "SettingsPresentationTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let app: AppDelegate
        var activations = 0
        var opens = 0

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let store = TerminalHostStore(defaults: defaults, discovery: TerminalHostDiscovery(candidates: { [] }))
            app = AppDelegate(terminalHostStore: store, activateSettingsApplication: {})
            app.testDefaults = defaults
            app.activateSettingsApplication = { [weak self] in self?.activations += 1 }
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
