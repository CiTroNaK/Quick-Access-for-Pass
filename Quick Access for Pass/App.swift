import SwiftUI
import AppKit
import Darwin

@main
struct QuickAccessPassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsRoot(appDelegate: appDelegate)
        }
    }
}

private struct SettingsRoot: View {
    let appDelegate: AppDelegate

    var body: some View {
        SettingsView()
            .environment(appDelegate.healthStore)
            .environment(appDelegate.passCLIStatusStore)
            .environment(\.databaseManager, appDelegate.databaseManager)
            .task { @MainActor in
                await appDelegate.healthCoordinator?.refreshAll()
            }
    }
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    @ObservationIgnored var panelController: PanelController?
    @ObservationIgnored private var largeTypeWindowController: LargeTypeWindowController?
    @ObservationIgnored private var statusBarController: StatusBarController?
    @ObservationIgnored private var hotkeyManager: HotkeyManager?
    @ObservationIgnored var viewModel: QuickAccessViewModel?

    @ObservationIgnored private(set) var cliService: PassCLIService?
    // Observed: SwiftUI Settings scene body evaluates eagerly at app init,
    // before applicationDidFinishLaunching runs setupServices(). Tracking
    // this property lets SettingsRoot re-render when it flips nil→set.
    private(set) var databaseManager: DatabaseManager?
    @ObservationIgnored private var searchService: SearchService?
    @ObservationIgnored private var clipboardManager: ClipboardManager?
    @ObservationIgnored var keychainService: KeychainService?

    @ObservationIgnored private var toastController: ToastWindowController?
    @ObservationIgnored private var refreshObserver: Any?
    @ObservationIgnored private var resetObserver: Any?
    @ObservationIgnored private var hotkeyObserver: Any?

    let healthStore = ProxyHealthStore()
    let passCLIStatusStore = PassCLIStatusStore()
    @ObservationIgnored private var wakeObserver: WakeObserver?

    @ObservationIgnored private var syncCoordinator: SyncCoordinator?
    @ObservationIgnored private var sshCoordinator: SSHProxyCoordinator?
    @ObservationIgnored var runCoordinator: RunProxyCoordinator?
    @ObservationIgnored var healthCoordinator: HealthCheckCoordinator?

    /// Lock state: set by `forceLock()`, cleared by `resetAuthTimestamp()`.
    private(set) var isForceLocked = false
    var lastAuthenticatedAt: Date?
    var panelPresentationNonce = UUID()
    private(set) var pendingLockContext: PendingLockContext?
    @ObservationIgnored var pendingUnlockWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Overridable defaults for testing. Production code uses `.standard`.
    var testDefaults: UserDefaults?
    private var lockDefaults: UserDefaults { testDefaults ?? .standard }

    var isLocked: Bool {
        _ = panelPresentationNonce
        if isForceLocked { return true }
        guard lockDefaults.bool(forKey: DefaultsKey.lockoutEnabled) else { return false }
        guard let lastAuth = lastAuthenticatedAt else { return true }
        let timeout = lockDefaults.object(forKey: DefaultsKey.lockoutTimeout) as? Double
            ?? LockoutTimeout.default.seconds
        return Date().timeIntervalSince(lastAuth) > timeout
    }

    var keychainServiceForLock: (any BiometricAuthorizing)? { keychainService }

    func resetAuthTimestamp() {
        lastAuthenticatedAt = Date()
        isForceLocked = false
        resumeUnlockWaiters()
    }

    func forceLock() {
        isForceLocked = true
    }

    // Token identifying the current pending-context writer. Cleared to nil
    // when the context is cleared. Writes only on MainActor.
    private var pendingLockContextToken: UUID?

    func setPendingLockContext(_ context: PendingLockContext) -> UUID {
        let token = UUID()
        pendingLockContextToken = token
        pendingLockContext = context
        return token
    }

    func clearPendingLockContext(token: UUID) {
        guard pendingLockContextToken == token else { return }
        pendingLockContextToken = nil
        pendingLockContext = nil
    }

    /// Invoked by `togglePanel()` to scrub any pending context on explicit
    /// user-initiated panel dismissal. Does not require a token because the
    /// user's action outranks any in-flight writer.
    func resetPendingLockContext() {
        pendingLockContextToken = nil
        pendingLockContext = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE so writes to a closed socket peer return EPIPE instead
        // of killing the process. Proxy code already catches EPIPE via failureSignal.
        signal(SIGPIPE, SIG_IGN)

        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else { return }

        NSApp.setActivationPolicy(.accessory)
        registerDefaultSettings()

        do {
            try setupServices()
            setupUI()
            setupHotkey()
            setupCoordinators()
            setupWakeObserver()
            runLaunchTimeSanityCheck()
        } catch {
            showSetupError(error)
        }
    }

    private func setupCoordinators() {
        syncCoordinator = SyncCoordinator(cliService: cliService!, databaseManager: databaseManager!, viewModel: viewModel!)
        syncCoordinator?.start()

        let authCallbacks = AuthDialogHelper.Callbacks(
            onAuthSuccess: { [weak self] in self?.resetAuthTimestamp() },
            onBiometryLockout: { [weak self] in self?.forceLock() }
        )

        sshCoordinator = makeSSHCoordinator(authCallbacks: authCallbacks)
        wireLockClosures(on: sshCoordinator)

        runCoordinator = makeRunCoordinator(authCallbacks: authCallbacks)
        wireLockClosures(on: runCoordinator)

        if let cliService, let runCoordinator, let sshCoordinator {
            healthCoordinator = HealthCheckCoordinator(
                cliStore: passCLIStatusStore,
                cliService: cliService,
                cliChecker: LivePassCLIHealthChecker(),
                runChecker: LiveRunProbeChecker(),
                sshChecker: LiveSSHProbeChecker(),
                runCoordinator: runCoordinator,
                sshCoordinator: sshCoordinator
            )
        }
    }

    private func setupWakeObserver() {
        wakeObserver = WakeObserver { [weak self] in
            await self?.healthCoordinator?.handleSystemWake()
        }
        wakeObserver?.start()
    }

    private func runLaunchTimeSanityCheck() {
        Task { [weak self] in
            await self?.healthCoordinator?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthCoordinator?.cancel()
        wakeObserver?.stop()
        clipboardManager?.clearOnTermination()
        sshCoordinator?.shutdown()
        runCoordinator?.shutdown()
    }

}

private extension AppDelegate {
    // MARK: - Setup

    // Note: Keychain IPC runs on MainActor here. Acceptable for a single sub-millisecond
    // passphrase read during launch in a menu-bar app with no visible UI at this point.
    func setupServices() throws {
        let keychainService = KeychainService()
        self.keychainService = keychainService
        let passphrase = try keychainService.getOrCreatePassphrase()

        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickAccessForPass")
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        let dbPath = appSupportURL.appendingPathComponent("app.db").path

        let rawClipboardTimeout = UserDefaults.standard.double(forKey: DefaultsKey.clipboardClearTimeout)
        let clipboardTimeout = rawClipboardTimeout > 0 ? rawClipboardTimeout : 30
        let cliPathOverride = UserDefaults.standard.string(forKey: DefaultsKey.cliPath)

        databaseManager = try Self.openDatabase(path: dbPath, passphrase: passphrase)
        cliService = PassCLIService(cliPath: cliPathOverride?.isEmpty == false ? cliPathOverride : nil)
        searchService = SearchService(databaseManager: databaseManager!)
        clipboardManager = ClipboardManager(autoClearSeconds: clipboardTimeout)
    }

    /// Opens the encrypted database, deleting and recreating it if the file is corrupt or
    /// was encrypted with a different passphrase (SQLite error 26). The DB is a local cache
    /// of data fetched from pass-cli, so losing it is safe — the next sync repopulates it.
    static func openDatabase(path: String, passphrase: Data) throws -> DatabaseManager {
        do {
            return try DatabaseManager(path: path, passphrase: passphrase)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "GRDB.DatabaseError" && nsError.code == 26 {
                try? FileManager.default.removeItem(atPath: path)
                return try DatabaseManager(path: path, passphrase: passphrase)
            }
            throw error
        }
    }

    func setupUI() {
        guard let searchService, let cliService, let clipboardManager else { return }

        configureToastAndPanel(clipboardManager: clipboardManager)
        configureViewModel(
            searchService: searchService,
            cliService: cliService,
            clipboardManager: clipboardManager
        )
        configureStatusBar()
        installUIObservers()
    }

    func configureToastAndPanel(clipboardManager: ClipboardManager) {
        toastController = ToastWindowController()
        clipboardManager.onCopy = { [weak self] message in self?.toastController?.show(message: message) }

        panelController = PanelController()
        largeTypeWindowController = LargeTypeWindowController()
        largeTypeWindowController?.onWindowShown = { [weak self] window in
            self?.panelController?.registerOwnedWindow(window)
        }
        largeTypeWindowController?.onWindowClosed = { [weak self] window in
            self?.panelController?.unregisterOwnedWindow(window)
        }
        panelController?.onHideAuxiliary = { [weak self] in
            self?.largeTypeWindowController?.close()
        }
    }

    func configureViewModel(
        searchService: SearchService,
        cliService: PassCLIService,
        clipboardManager: ClipboardManager
    ) {
        viewModel = QuickAccessViewModel(
            searchService: searchService,
            cliService: cliService,
            clipboardManager: clipboardManager,
            onDismiss: { [weak self] in self?.panelController?.hide() },
            presentLargeType: { [weak self] display in
                guard let self else { return }
                self.largeTypeWindowController?.show(
                    display: display,
                    relativeTo: self.panelController?.windowForPresentation
                )
            }
        )

        guard let viewModel else { return }

        let quickAccessView = QuickAccessView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.panelController?.hide() },
            appDelegate: self
        )
        panelController?.setContent(quickAccessView)
        panelController?.onShow = { [weak self] in self?.viewModel?.cancelSearchClear() }
        panelController?.onHide = { [weak self] in self?.viewModel?.scheduleSearchClear() }
        panelController?.onKeyDown = { [weak self] keyCode, mods in
            self?.viewModel?.handleKeyDown(keyCode: keyCode, modifiers: mods) ?? false
        }
    }

    func configureStatusBar() {
        statusBarController = StatusBarController(
            healthStore: healthStore,
            passCLIStatusStore: passCLIStatusStore,
            onToggle: { [weak self] in self?.togglePanel() },
            onRefresh: { [weak self] in
                self?.syncCoordinator?.refreshNow()
                Task { [weak self] in
                    await self?.healthCoordinator?.refreshAll()
                }
            },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    func installUIObservers() {
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .refreshRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncCoordinator?.refreshNow()
            }
        }

        resetObserver = NotificationCenter.default.addObserver(
            forName: .resetDatabaseRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncCoordinator?.resetAndSync()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                guard let pc = self?.panelController,
                      pc.isVisible,
                      !pc.isShowingTransition,
                      !pc.isOwnWindow(window) else { return }
                pc.hide()
            }
        }
    }

    func setupHotkey() {
        hotkeyManager = HotkeyManager()
        reloadHotkey()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadHotkey()
                self?.syncCoordinator?.reloadTimerIfNeeded()
                let cliPathChanged = self?.applyCLIPathOverride() ?? false
                await self?.sshCoordinator?.reconcile()
                await self?.runCoordinator?.reconcile()
                if cliPathChanged {
                    await self?.healthCoordinator?.refreshAll()
                }
            }
        }
    }

    /// Pushes the current `DefaultsKey.cliPath` into `cliService`, returning
    /// true iff the resolved path changed. Sequencing matters: coordinators
    /// and the health probe must observe the new value, so this runs before
    /// reconcile() + refreshAll() in the UserDefaults change observer.
    func applyCLIPathOverride() -> Bool {
        guard let cliService else { return false }
        let override = UserDefaults.standard.string(forKey: DefaultsKey.cliPath)
        let resolved: String
        if let override, !override.isEmpty {
            resolved = override
        } else {
            resolved = PassCLIService.findCLIPath() ?? "pass-cli"
        }
        guard resolved != cliService.cliPath else { return false }
        cliService.updateCLIPath(resolved)
        return true
    }

    func reloadHotkey() {
        let defaults = UserDefaults.standard
        let code = defaults.integer(forKey: DefaultsKey.hotkeyCode)
        let mods = defaults.integer(forKey: DefaultsKey.hotkeyModifiers)

        hotkeyManager?.keyCode = code > 0 ? UInt16(code) : 49
        hotkeyManager?.modifiers = mods > 0
            ? NSEvent.ModifierFlags(rawValue: UInt(mods))
            : [.shift, .option]

        hotkeyManager?.register { [weak self] in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
    }

}
