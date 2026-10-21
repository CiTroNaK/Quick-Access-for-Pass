import AppKit
import Testing
@testable import Quick_Access_for_Pass

@Suite("Status bar menu")
@MainActor
struct StatusBarMenuTests {
    @Test func disabledProxiesHaveNoStatusRows() {
        let fixture = Fixture()
        let menu = fixture.controller.makeMenu()
        menu.update()
        let statusRows = menu.items.filter { !$0.isSeparatorItem && !$0.isEnabled }
        #expect(statusRows.count == 1)
        #expect(statusRows.first?.title.contains("Pass CLI") == true)
        #expect(statusRows.first?.image != nil)
    }

    @Test func enabledProxiesHaveDisabledColoredStatusRows() {
        let fixture = Fixture()
        fixture.health.sshHealth = .ok(detail: "3 keys")
        fixture.health.runHealth = .degraded(.cooldown)
        let menu = fixture.controller.makeMenu()
        menu.update()
        let rows = menu.items.filter { !$0.isSeparatorItem && !$0.isEnabled }
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.image != nil })
        #expect(rows[1].title.contains("SSH Agent"))
        #expect(rows[2].title.contains("Run Proxy"))
    }

    @Test(arguments: [PassCLIHealth.ok, .notInstalled, .notLoggedIn, .localSessionUnreadable])
    func loginActionIsPresentOnlyForAuthenticationRecovery(health: PassCLIHealth) {
        let fixture = Fixture()
        fixture.cli.health = health
        let menu = fixture.controller.makeMenu()
        menu.update()
        let loginItems = menu.items.filter { $0.title == health.loginActionTitle }
        let expected = health == .notLoggedIn || health == .localSessionUnreadable
        #expect(loginItems.count == (expected ? 1 : 0))
        if expected, let index = menu.items.firstIndex(where: { $0.title == health.loginActionTitle }) {
            menu.performActionForItem(at: index)
            #expect(fixture.actions.filter { $0 != "foreground" } == ["login"])
        }
    }

    @Test func refreshAndQuitKeepTheirShortcutsAndCallbacks() throws {
        let fixture = Fixture()
        let menu = fixture.controller.makeMenu()
        menu.update()
        let refresh = try #require(menu.items.firstIndex { $0.title == String(localized: "Refresh Now") })
        let quit = try #require(menu.items.firstIndex { $0.title == String(localized: "Quit") })
        #expect(refresh < quit)
        #expect(menu.items[refresh].keyEquivalent == "r")
        #expect(menu.items[quit].keyEquivalent == "q")
        #expect(menu.items[refresh].keyEquivalentModifierMask == .command)
        #expect(menu.items[quit].keyEquivalentModifierMask == .command)
        menu.performActionForItem(at: refresh)
        menu.performActionForItem(at: quit)
        #expect(fixture.actions.filter { $0 != "foreground" } == ["refresh", "quit"])
    }

    @Test func settingsIsDiscoverableBeforeQuitWithCommandComma() throws {
        let fixture = Fixture()
        let menu = fixture.controller.makeMenu()
        menu.update()
        let items = menu.items.filter { $0.title == String(localized: "Settings…") }
        #expect(items.count == 1)
        let settings = try #require(menu.items.firstIndex { $0.title == String(localized: "Settings…") })
        let quit = try #require(menu.items.firstIndex { $0.title == String(localized: "Quit") })
        #expect(settings < quit)
        #expect(menu.items[settings].keyEquivalent == ",")
        #expect(menu.items[settings].keyEquivalentModifierMask == .command)
        #expect(menu.items[settings].isEnabled)
    }

    @Test func coldSettingsActionCapturesForegroundBeforeMenuWithoutTogglingPanel() throws {
        let fixture = Fixture()
        let menu = fixture.controller.makeMenu()
        menu.update()
        #expect(fixture.actions == ["foreground"])
        let index = try #require(menu.items.firstIndex { $0.title == String(localized: "Settings…") })
        menu.performActionForItem(at: index)
        #expect(fixture.actions == ["foreground", "settings"])
        #expect(fixture.settingsRestorationTarget == nil)
    }

    @MainActor
    private final class Fixture {
        let health = ProxyHealthStore()
        let cli = PassCLIStatusStore()
        var actions: [String] = []
        var settingsRestorationTarget: NSRunningApplication?
        lazy var controller = StatusBarController(
            healthStore: health,
            passCLIStatusStore: cli,
            onToggle: { [weak self] in self?.actions.append("toggle") },
            onRefresh: { [weak self] in self?.actions.append("refresh") },
            onLoginPassCLI: { [weak self] in self?.actions.append("login") },
            onQuit: { [weak self] in self?.actions.append("quit") },
            onOpenSettings: { [weak self] _, application in
                self?.actions.append("settings")
                self?.settingsRestorationTarget = application
            },
            frontmostApplication: { [weak self] in
                self?.actions.append("foreground")
                return .current
            },
            makeStatusItem: { nil }
        )
    }
}
