import Testing
@testable import Quick_Access_for_Pass

@Suite("Settings animation admission")
struct SettingsAnimationPolicyTests {
    @Test(arguments: SettingsTab.allCases, [false, true])
    func onlyTheVisibleSelectedProxyTabIsAdmitted(selected: SettingsTab, visible: Bool) {
        let expectedWhenVisible: [SettingsTab: [Bool]] = [.ssh: [true, false], .run: [false, true]]
        let expected = visible ? expectedWhenVisible[selected, default: [false, false]] : [false, false]
        #expect(SettingsAnimationPolicy.isActive(isWindowVisible: visible, selectedTab: selected, tab: .ssh) == expected[0])
        #expect(SettingsAnimationPolicy.isActive(isWindowVisible: visible, selectedTab: selected, tab: .run) == expected[1])
    }

    @Test(arguments: [ProxyHealthState.disabled, .ok(), .degraded(.cooldown), .unreachable(.probeFailed)], [false, true])
    func reduceMotionAlwaysSuppressesPulse(state: ProxyHealthState, animationsActive: Bool) {
        #expect(!StatusIndicator.isPulseEnabled(state: state, animationsActive: animationsActive, reduceMotion: true))
    }

    @Test(arguments: [ProxyHealthState.disabled, .ok(), .degraded(.cooldown), .unreachable(.probeFailed)])
    func inactiveEnvironmentAlwaysSuppressesPulse(state: ProxyHealthState) {
        #expect(!StatusIndicator.isPulseEnabled(state: state, animationsActive: false, reduceMotion: false))
    }

    @Test(arguments: [ProxyHealthState.ok(), .degraded(.emptyIdentities), .unreachable(.probeFailed)])
    func activeStatusReadmitsAfterWindowOrTabReturns(state: ProxyHealthState) {
        #expect(StatusIndicator.isPulseEnabled(state: state, animationsActive: true, reduceMotion: false))
        #expect(!StatusIndicator.isPulseEnabled(state: state, animationsActive: false, reduceMotion: false))
        #expect(StatusIndicator.isPulseEnabled(state: state, animationsActive: true, reduceMotion: false))
        #expect(!StatusIndicator.isPulseEnabled(state: state, animationsActive: true, reduceMotion: true))
        #expect(StatusIndicator.isPulseEnabled(state: state, animationsActive: true, reduceMotion: false))
    }

    @Test func disabledStatusNeverPulsesEvenInAnEligibleWindow() {
        #expect(!StatusIndicator.isPulseEnabled(state: .disabled, animationsActive: true, reduceMotion: false))
    }
}
