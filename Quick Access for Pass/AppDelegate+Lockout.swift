import AppKit

extension AppDelegate {
    private var lockDefaults: UserDefaults { testDefaults ?? .standard }

    var isLocked: Bool {
        _ = panelPresentationNonce
        if isForceLocked { return true }
        guard lockDefaults.bool(forKey: DefaultsKey.lockoutEnabled) else { return false }
        guard let lastActivity = lastActivityAt else { return true }
        let timeout = lockDefaults.object(forKey: DefaultsKey.lockoutTimeout) as? Double
            ?? LockoutTimeout.default.seconds
        return Date().timeIntervalSince(lastActivity) > timeout
    }

    var keychainServiceForLock: (any BiometricAuthorizing)? { keychainService }

    func recordActivity() {
        lastActivityAt = Date()
    }

    func resetAuthTimestamp() {
        let now = Date()
        lastAuthenticatedAt = now
        lastActivityAt = now
        isForceLocked = false
        resumeUnlockWaiters()
        hidePanelAfterLockWaitIfNeeded()
    }

    /// Bumps `autoUnlockToken` after a short settle delay when the
    /// panel has become visible and the app is locked. The delay lets
    /// `makeKeyAndOrderFront(nil)` + `NSApp.activate()` finish settling
    /// before the LAContext auth sheet attaches, so the sheet lands on a
    /// real key window and receives focus. The post-delay re-checks
    /// defend against a hide-then-show racing the dispatch.
    func scheduleAutoUnlockIfNeeded() {
        guard isLocked else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.isLocked,
                  self.panelController?.isVisible == true
            else { return }
            self.autoUnlockToken = UUID()
        }
    }

    /// If the panel was opened by `showPanelAndWaitForUnlock` (not by
    /// user action), dismiss it on the next run loop. Deferring past
    /// the current stack lets `LockedView.unlock()`'s `defer` clear
    /// `isUnlockInFlight` first, so `PanelController.shouldBlockHide`
    /// no longer blocks the hide.
    private func hidePanelAfterLockWaitIfNeeded() {
        guard panelShownForLockWait else { return }
        panelShownForLockWait = false
        DispatchQueue.main.async { [weak self] in
            self?.panelController?.hide()
        }
    }

    func forceLock() {
        isForceLocked = true
    }

    func registerDefaultSettings() {
        // Carbon keyCode 8 = "C", modifier raw values:
        // ⌘ = 1048576, ⇧⌘ = 1179648, ⌥⌘ = 1572864
        UserDefaults.standard.register(defaults: [
            DefaultsKey.concealFromClipboardManagers: true,
            DefaultsKey.searchClearTimeout: 60.0,
            DefaultsKey.copyUsernameKeyCode: 8,
            DefaultsKey.copyUsernameModifiers: 1048576,
            DefaultsKey.copyPasswordKeyCode: 8,
            DefaultsKey.copyPasswordModifiers: 1179648,
            DefaultsKey.copyTotpKeyCode: 8,
            DefaultsKey.copyTotpModifiers: 1572864,
            DefaultsKey.showLargeTypeKeyCode: 36,
            DefaultsKey.showLargeTypeModifiers: Int(NSEvent.ModifierFlags.shift.rawValue),
            DefaultsKey.lockoutEnabled: false,
            DefaultsKey.lockoutTimeout: LockoutTimeout.default.seconds,
        ])
    }

    func togglePanel() {
        guard let panelController else { return }
        if panelController.isVisible {
            panelController.hide()
        } else {
            resetPendingLockContext()
            panelPresentationNonce = UUID()
            panelController.show()
        }
    }

    func showSetupError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Setup Failed")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Shows the locked panel and awaits unlock or the timeout,
    /// whichever comes first. Replaces the previous polling loop.
    ///
    /// Implementation: every caller gets its own `CheckedContinuation`
    /// stored in `pendingUnlockWaiters`. A sibling Task resumes with
    /// `false` after the timeout. `resetAuthTimestamp()` drains all
    /// armed waiters with `true`. Whichever side runs
    /// `removeValue(forKey:)` first wins; the loser's lookup returns nil
    /// and skips the resume. Both paths execute on `@MainActor`, so the
    /// remove-then-resume sequence is serialized with other mutators.
    ///
    /// The `withCheckedContinuation` body is synchronous — `cont` is
    /// stored and the timeout Task is armed before the function
    /// suspends, so there is no window where the timeout could fire
    /// against an unregistered continuation.
    ///
    /// `Task.sleep(for:)` uses `ContinuousClock`, which advances
    /// during system sleep. A machine that sleeps mid-wait will wake
    /// with the timeout already expired. This matches the previous
    /// polling loop's behavior.
    ///
    /// `timeoutSeconds` defaults to 30 s; tests pass a smaller value
    /// for the timeout branch.
    func showPanelAndWaitForUnlock(timeoutSeconds: TimeInterval = 30) async -> Bool {
        let token = UUID()
        panelPresentationNonce = token
        if panelController?.isVisible != true {
            panelShownForLockWait = true
        }
        panelController?.show()

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingUnlockWaiters[token] = cont
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if let waiter = pendingUnlockWaiters.removeValue(forKey: token) {
                    waiter.resume(returning: false)
                    self.hidePanelAfterLockWaitIfNeeded()
                }
            }
        }
    }

    func resumeUnlockWaiters() {
        // Copy before clearing so resume calls cannot observe the
        // half-drained dict.
        let waiters = pendingUnlockWaiters
        pendingUnlockWaiters.removeAll()
        for (_, cont) in waiters {
            cont.resume(returning: true)
        }
    }
}
