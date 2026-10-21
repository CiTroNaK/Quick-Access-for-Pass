#if QA_SETTINGS_UI_ACCEPTANCE
import AppKit
import Observation
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

/// Owns only synthetic windows, private defaults, and metadata-only lifecycle observations.
@MainActor
@Observable
final class SettingsStatusIndicatorHostingFixture {
    enum Mode { case tabs, indicator }
    enum Failure: Error { case timedOut(String), cancelled }

    /// A matched event, not a promise that later native window events cannot change live state.
    struct LifecycleObservation: Sendable {
        let appearances: Int
        let disappearances: Int
        let windowEligible: Bool
    }

    let mode: Mode
    var selectedTab: SettingsTab = .ssh
    var reduceMotion = false
    var animationsActive = true
    var state: ProxyHealthState = .ok()
    private(set) var appearances = 0
    private(set) var disappearances = 0

    @ObservationIgnored let window: NSWindow
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let suite: String
    @ObservationIgnored let health = ProxyHealthStore()
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var nativeEvents: [String] = []
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var target: (appearances: Int, disappearances: Int, visibility: Bool)?
    @ObservationIgnored private var waiter: CheckedContinuation<LifecycleObservation, any Error>?
    @ObservationIgnored lazy var coordinator = SettingsWindowCoordinator(
        isCurrentApplicationActive: { false }, activateApplication: { _ in }
    )
    @ObservationIgnored lazy var observer = SettingsPulseLifecycleObserver { [weak self] present in
        self?.record(present)
    }

    init(mode: Mode) throws {
        self.mode = mode
        suite = "SettingsUIAcceptance.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic Settings acceptance"
        health.sshHealth = .ok()
        health.runHealth = .ok()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification, NSWindow.didUpdateNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordNativeEvent(name) }
            }
            notificationTokens.append(token)
        }
        window.contentView = NSHostingView(rootView: SettingsStatusIndicatorHostingView(fixture: self))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // A test host may not own NSApplication's normal event/update loop. Drive one real
        // AppKit update for this owned window, not a fabricated notification or polling loop.
        window.update()
    }

    func clean() {
        timeoutTask?.cancel()
        timeoutTask = nil
        finishWait(throwing: Failure.cancelled)
        window.contentView = nil
        window.close()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        defaults.removePersistentDomain(forName: suite)
    }

    @discardableResult
    func waitForLifecycle(appearances: Int, disappearances: Int, visibility: Bool = true) async throws -> LifecycleObservation {
        if matches(appearances: appearances, disappearances: disappearances, visibility: visibility) { return lifecycleObservation }
        try #require(waiter == nil, "Fixture supports one awaited transition at a time")
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            target = (appearances, disappearances, visibility)
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                self.finishWait(throwing: Failure.timedOut(
                    "expected lifecycle \(appearances)/\(disappearances), got \(self.appearances)/\(self.disappearances); "
                    + self.nativeState + "; events=" + self.nativeEvents.joined(separator: " | ")
                ))
            }
        }
    }

    private var lifecycleObservation: LifecycleObservation {
        LifecycleObservation(appearances: appearances, disappearances: disappearances,
                             windowEligible: coordinator.isSettingsWindowVisible)
    }

    private var nativeState: String {
        "visible=\(window.isVisible), mini=\(window.isMiniaturized), occlusion=\(window.occlusionState.rawValue), "
        + "eligible=\(coordinator.isSettingsWindowVisible), attached=\(window.contentView?.window === window), tab=\(selectedTab.rawValue), "
        + "appRunning=\(NSApp.isRunning), policy=\(NSApp.activationPolicy().rawValue), key=\(window.isKeyWindow)"
    }

    private func recordNativeEvent(_ name: Notification.Name) {
        guard nativeEvents.count < 64 else { return }
        if name == NSWindow.didUpdateNotification, coordinator.isSettingsWindowVisible { return }
        nativeEvents.append(name.rawValue + ": " + nativeState)
    }

    func windowEligibilityDidChange() {
        resumeIfReady()
    }

    private func matches(appearances: Int, disappearances: Int, visibility: Bool) -> Bool {
        self.appearances >= appearances && self.disappearances >= disappearances
            && coordinator.isSettingsWindowVisible == visibility
    }

    private func record(_ present: Bool) {
        if present { appearances += 1 } else { disappearances += 1 }
        resumeIfReady()
    }

    private func resumeIfReady() {
        guard let target, matches(appearances: target.appearances, disappearances: target.disappearances,
                                  visibility: target.visibility) else { return }
        finishWait()
    }

    private func finishWait(throwing error: (any Error)? = nil) {
        let continuation = waiter
        waiter = nil
        target = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: lifecycleObservation) }
    }
}
#endif
