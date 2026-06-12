import Testing
@testable import Quick_Access_for_Pass

@Suite("SecuritySettingsTab")
@MainActor
struct SecuritySettingsTabTests {
    @Test func deniedDisableRestoresLockToggle() async {
        var value = false
        var authCallCount = 0

        await SecuritySettingsTab.restoreLockToggleIfDisableDenied(
            oldValue: true,
            newValue: false,
            setValue: { value = $0 },
            authorize: {
                authCallCount += 1
                return false
            }
        )

        #expect(value)
        #expect(authCallCount == 1)
    }

    @Test func allowedDisableLeavesLockToggleDisabled() async {
        var value = false
        var authCallCount = 0

        await SecuritySettingsTab.restoreLockToggleIfDisableDenied(
            oldValue: true,
            newValue: false,
            setValue: { value = $0 },
            authorize: {
                authCallCount += 1
                return true
            }
        )

        #expect(value == false)
        #expect(authCallCount == 1)
    }

    @Test func enablingLockToggleDoesNotRequestAuthorization() async {
        var value = true
        var authCallCount = 0

        await SecuritySettingsTab.restoreLockToggleIfDisableDenied(
            oldValue: false,
            newValue: true,
            setValue: { value = $0 },
            authorize: {
                authCallCount += 1
                return false
            }
        )

        #expect(value)
        #expect(authCallCount == 0)
    }
}
