// swiftlint:disable file_length
// AppDelegate is the deliberately co-located composition root; split helpers
// would require widening composition-only access beyond this file.

import SwiftUI
import AppKit
import Darwin

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    @ObservationIgnored var panelController: PanelController?
    /// Injectable so key-window notification ordering can be tested without WindowServer races.
    @ObservationIgnored var keyWindowProvider: () -> NSWindow? = { NSApp.keyWindow }
    @ObservationIgnored private var largeTypeWindowController: LargeTypeWindowController?
    @ObservationIgnored var syncIssueWindowController: SyncIssueWindowController?
    @ObservationIgnored var settingsWindowCoordinator = SettingsWindowCoordinator()
    @ObservationIgnored private var statusBarController: StatusBarController?
    @ObservationIgnored private var hotkeyManager: HotkeyManager?
    @ObservationIgnored var viewModel: QuickAccessViewModel?
    /// Shared by every host secret release path so lifecycle revocation has one authority.
    @ObservationIgnored let secretReleaseGuard = SecretReleaseGuard()

    @ObservationIgnored private(set) var cliService: PassCLIService?
    // Observed: SwiftUI Settings scene body evaluates eagerly at app init,
    // before applicationDidFinishLaunching runs setupServices(). Tracking
    // this property lets SettingsRoot re-render when it flips nil→set.
    private(set) var databaseManager: DatabaseManager?
    @ObservationIgnored private var searchService: SearchService?
    @ObservationIgnored private var clipboardManager: ClipboardManager?
    @ObservationIgnored var keychainService: KeychainService?
    @ObservationIgnored var offlineSnapshotRepository: OfflineSnapshotRepository?
    @ObservationIgnored var offlineSnapshotCodec: OfflineSnapshotCodec?
    @ObservationIgnored var offlineModeService: OfflineModeService?
    @ObservationIgnored var offlineStorageMaintenance: OfflineStorageMaintenance?
    @ObservationIgnored var offlineModeCoordinator: OfflineModeCoordinator?
    @ObservationIgnored var offlineSecretResolver: OfflineSecretResolver?

    @ObservationIgnored private var toastController: ToastWindowController?
    @ObservationIgnored private var refreshObserver: Any?
    @ObservationIgnored private var resetObserver: Any?
    @ObservationIgnored private var hotkeyObserver: Any?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var didPerformSynchronousTerminationCleanup = false
    @ObservationIgnored private(set) var isTerminating = false
    @ObservationIgnored lazy var terminationCoordinator: AppTerminationCoordinator = makeTerminationCoordinator()

    let healthStore = ProxyHealthStore()
    let passCLIStatusStore = PassCLIStatusStore()
    @ObservationIgnored var wakeObserver: WakeObserver?
    @ObservationIgnored var systemLockObserver: SystemLockObserver?

    @ObservationIgnored var syncCoordinator: SyncCoordinator?
    @ObservationIgnored var sshCoordinator: SSHProxyCoordinator?
    @ObservationIgnored var runCoordinator: RunProxyCoordinator?
    @ObservationIgnored var autoFillBrokerCoordinator: AutoFillBrokerCoordinator?
    /// Created before service setup so a nonactivating launch URL can register
    /// its bounded wake handle while the quit host is still starting.
    @ObservationIgnored var autoFillRequestRegistry = AutoFillRequestRegistry()
    @ObservationIgnored let autoFillLaunchGate = AutoFillLaunchGate()
    @ObservationIgnored var autoFillLaunchNow: @Sendable () -> UInt64 = {
        DispatchTime.now().uptimeNanoseconds
    }
    @ObservationIgnored var autoFillBroker: AutoFillBroker?
    @ObservationIgnored var autoFillBrokerStartTask: Task<Void, Never>?
    @ObservationIgnored var autoFillDatabaseURL: URL?
    @ObservationIgnored var autoFillSocketPath: String?
    @ObservationIgnored var healthCoordinator: HealthCheckCoordinator?
    @ObservationIgnored var notificationRouter: UserNotificationRouter?
    @ObservationIgnored var passCLILoginCoordinator: PassCLILoginCoordinator?
    @ObservationIgnored var passCLILoginNotifier: PassCLILoginNotifier?
    @ObservationIgnored var passCLIRecommendedVersionNotifier: PassCLIRecommendedVersionNotifier?
    @ObservationIgnored var passCLIPATCredentialStore: KeychainPassCLIPATCredentialStore?
    @ObservationIgnored var passCLIPATLoginService: PassCLIPATLoginService?
    @ObservationIgnored var passCLIPATAutoLoginCoordinator: PassCLIPATAutoLoginCoordinator?
    var passCLIPATSettingsModel: PassCLIPATSettingsModel?
    @ObservationIgnored var passCLILoginObserver: Any?

    /// Lock state: set by `forceLock()`, cleared by `resetAuthTimestamp()`.
    var isForceLocked = false
    var lastAuthenticatedAt: Date?
    var lastActivityAt: Date?
    var panelPresentationNonce = UUID()
    /// Bumped by `scheduleAutoUnlockIfNeeded()` on each fresh locked
    /// presentation. Observed by `LockedView.task(id:)` to drive auto-unlock.
    var autoUnlockToken: UUID?
    /// Bumped when AutoFill authentication failure handling asks the locked
    /// view to restore VoiceOver focus to its unlock action.
    var unlockAccessibilityFocusRequestID: UUID?
    /// Bumped whenever a visible unlocked panel should put keyboard focus
    /// back into the SwiftUI search field. Hiding the panel can leave
    /// `@FocusState` out of sync with AppKit's first responder, so each
    /// presentation needs an explicit focus request.
    var searchFocusRequestID: UUID?
    /// True while `LockedView.unlock()` owns the single active panel
    /// authentication attempt. Read by `PanelController.shouldBlockHide`
    /// to keep the panel anchored while an LAContext sheet is on screen.
    var isUnlockInFlight = false
    /// Token for the single active panel authentication attempt. The token
    /// prevents a rejected or stale attempt from ending the active attempt.
    @ObservationIgnored var panelUnlockAttemptID: UUID?
    /// True when `showPanelAndWaitForUnlock` opened the panel itself
    /// (not already visible). Consumed by `hidePanelAfterLockWaitIfNeeded`
    /// so a system-initiated presentation closes the panel after unlock,
    /// rather than transitioning to the search UI.
    @ObservationIgnored var panelShownForLockWait = false
    private(set) var pendingLockContext: PendingLockContext?
    @ObservationIgnored var pendingUnlockWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Injectable timeout wait that keeps unlock-waiter tests deterministic.
    @ObservationIgnored var waitForUnlockTimeout: @MainActor @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Overridable defaults for testing. Production code uses `.standard`.
    var testDefaults: UserDefaults?

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

        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await setupServices()
                try Task.checkCancellation()
                setupUI()
                setupHotkey()
                setupCoordinators()
                setupWakeObserver()
                setupSystemLockObserver()
                runLaunchTimeSanityCheck()
            } catch is CancellationError {
                return
            } catch {
                showSetupError(error)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        performSynchronousTerminationCleanup()
        return terminationCoordinator.beginTermination()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // This callback cannot await. The asynchronous termination coordinator
        // already joined owned startup/maintenance/broker work when AppKit used
        // applicationShouldTerminate; direct callback tests remain synchronous.
        performSynchronousTerminationCleanup()
    }

    private func performSynchronousTerminationCleanup() {
        guard !didPerformSynchronousTerminationCleanup else { return }
        didPerformSynchronousTerminationCleanup = true
        isTerminating = true
        secretReleaseGuard.blockReleasesForTermination()
        cancelPanelUnlock()
        panelController?.hide(ignoringBlock: true)
        revokeTransientSecretAccess()
        setupTask?.cancel()
        autoFillBrokerStartTask?.cancel()
        passCLILoginCoordinator?.cancel()
        healthCoordinator?.cancel()
        wakeObserver?.stop()
        systemLockObserver?.stop()
        clipboardManager?.clearOnTermination()
        sshCoordinator?.shutdown()
        runCoordinator?.shutdown()
        offlineModeCoordinator?.stopObservation()
        if let socketPath = autoFillSocketPath {
            unlink(socketPath)
        }
    }

    /// Opens an existing or newly initialized database without destructive recovery.
    /// A wrong key or malformed database is always surfaced to the caller unchanged.
    nonisolated static func openDatabase(path: String, passphrase: Data) throws -> DatabaseManager {
        try DatabaseManager(path: path, passphrase: passphrase)
    }

    /// Revokes only transient host-owned secret presentation. It intentionally
    /// does not promise to retract values that were already released.
    func revokeTransientSecretAccess() {
        secretReleaseGuard.revoke()
        viewModel?.cancelSecretActions()
        // Production composition owns this instance; the view-model fallback
        // preserves the same ownership rule in lifecycle-focused test wiring.
        (clipboardManager ?? viewModel?.clipboardManager)?.clearIfOwned()
        largeTypeWindowController?.close()
    }
}

private extension AppDelegate {
    func makeTerminationCoordinator() -> AppTerminationCoordinator {
        AppTerminationCoordinator(
            cancelStartup: { [weak self] in self?.setupTask?.cancel() },
            cancelBrokerStart: { [weak self] in self?.autoFillBrokerStartTask?.cancel() },
            awaitStartup: { [weak self] in
                guard let task = self?.setupTask else { return }
                await task.value
            },
            awaitBrokerStart: { [weak self] in
                guard let task = self?.autoFillBrokerStartTask else { return }
                await task.value
            },
            stopOfflineWork: { [weak self] in
                await self?.offlineModeService?.stop()
            },
            stopMaintenance: { [weak self] in
                await self?.offlineStorageMaintenance?.stop()
            },
            stopBroker: { [weak self] in
                await self?.autoFillBroker?.stop()
            },
            reply: {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        )
    }

    // MARK: - Setup

    func setupServices() async throws {
        // Keychain and SQLCipher I/O stay off MainActor. The database remains
        // host-owned in Application Support; only the broker socket uses App Group storage.
        let prepared = try await Task.detached(priority: .userInitiated) {
            let keychainService = KeychainService()
            let database = try DatabaseStartupPreparation.prepare(
                keychainService: keychainService
            )
            let databaseManager = try Self.openDatabase(
                path: database.databaseURL.path,
                passphrase: database.passphrase
            )
            let socketPath = try AutoFillConstants.brokerSocketURL().path
            return (keychainService, databaseManager, database.databaseURL, socketPath)
        }.value
        try Task.checkCancellation()

        keychainService = prepared.0
        databaseManager = prepared.1
        autoFillDatabaseURL = prepared.2
        autoFillSocketPath = prepared.3

        let (offlineStorageMaintenance, offlineSnapshotRepository, offlineSnapshotCodec) = configureOfflineStorage(database: prepared.1)

        let rawClipboardTimeout = UserDefaults.standard.double(forKey: DefaultsKey.clipboardClearTimeout)
        let clipboardTimeout = rawClipboardTimeout > 0 ? rawClipboardTimeout : 30
        let cliPathOverride = UserDefaults.standard.string(forKey: DefaultsKey.cliPath)
        let selectionRaw = UserDefaults.standard.string(forKey: DefaultsKey.passCLISelection)
        let selectionPreference = PassCLISelectionPreference.resolved(
            rawValue: selectionRaw,
            legacyCustomPath: cliPathOverride
        )

        let cliService = PassCLIService(
            preference: selectionPreference,
            customPath: cliPathOverride?.isEmpty == false ? cliPathOverride : nil
        )
        self.cliService = cliService
        let offlineModeService = OfflineModeService(
            repository: offlineSnapshotRepository,
            codec: offlineSnapshotCodec,
            cliService: cliService,
            maintenance: offlineStorageMaintenance
        )
        self.offlineModeService = offlineModeService
        // Recovery failure keeps normal live setup usable. Offline selection and
        // cached resolution remain unavailable until an explicit retry succeeds.
        try? await offlineModeService.initialize()
        try Task.checkCancellation()
        offlineSecretResolver = OfflineSecretResolver(
            cliService: cliService,
            repository: offlineSnapshotRepository,
            codec: offlineSnapshotCodec,
            readiness: offlineModeService
        )
        searchService = SearchService(databaseManager: databaseManager!)
        clipboardManager = ClipboardManager(autoClearSeconds: clipboardTimeout)
    }

    private func configureOfflineStorage(database: DatabaseManager) -> (
        OfflineStorageMaintenance, OfflineSnapshotRepository, OfflineSnapshotCodec
    ) {
        let offlineStorageMaintenance = OfflineStorageMaintenance(
            checkpointer: DatabaseWALCheckpointer(writer: database.writer)
        )
        let offlineSnapshotRepository = OfflineSnapshotRepository(
            database: database,
            maintenance: offlineStorageMaintenance
        )
        let offlineSnapshotCodec = OfflineSnapshotCodec(
            keyMaterialProvider: OfflineKeyMaterialStore(),
            hasPersistedSnapshots: { try await offlineSnapshotRepository.hasPersistedSnapshots() }
        )
        self.offlineSnapshotRepository = offlineSnapshotRepository
        self.offlineSnapshotCodec = offlineSnapshotCodec
        self.offlineStorageMaintenance = offlineStorageMaintenance
        return (offlineStorageMaintenance, offlineSnapshotRepository, offlineSnapshotCodec)
    }

    func setupUI() {
        guard let searchService, let cliService, let clipboardManager else { return }

        configureToastAndPanel(clipboardManager: clipboardManager)
        configureViewModel(
            searchService: searchService,
            cliService: cliService,
            clipboardManager: clipboardManager,
            secretResolver: offlineSecretResolver ?? LiveSecretItemResolver(cliService: cliService)
        )
        configureStatusBar()
        installUIObservers()
    }

    func configureToastAndPanel(clipboardManager: ClipboardManager) {
        toastController = ToastWindowController()
        clipboardManager.onCopy = { [weak self] message in self?.toastController?.show(message: message) }

        panelController = PanelController()
        largeTypeWindowController = LargeTypeWindowController()
        largeTypeWindowController?.onWindowPrepared = { [weak self] window in
            self?.panelController?.registerOwnedWindow(window)
        }
        largeTypeWindowController?.onPreparationDiscarded = { [weak self] window in
            self?.panelController?.unregisterOwnedWindow(window)
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
        clipboardManager: ClipboardManager,
        secretResolver: any SecretItemResolving
    ) {
        let offlineModeCoordinator = offlineModeService.map { service in
            OfflineModeCoordinator(
                service: service,
                observation: OfflineCatalogObservation(database: databaseManager!),
                shareIDForVault: { vaultID in
                    try? searchService.vaultShareId(for: vaultID)
                }
            )
        }
        self.offlineModeCoordinator = offlineModeCoordinator
        offlineModeCoordinator?.startObservation()

        viewModel = QuickAccessViewModel(
            searchService: searchService,
            cliService: cliService,
            clipboardManager: clipboardManager,
            onDismiss: { [weak self] in self?.panelController?.hide() },
            onActivity: { [weak self] in self?.recordActivity() },
            secretResolver: secretResolver,
            offlineModeCoordinator: offlineModeCoordinator,
            secretReleaseGuard: secretReleaseGuard,
            largeTypePresentation: LargeTypePresentationActions(
                prepare: { [weak self] display in
                    guard let self, let controller = self.largeTypeWindowController else { throw CancellationError() }
                    return controller.prepare(display: display, relativeTo: self.panelController?.windowForPresentation)
                },
                activate: { [weak self] prepared in
                    guard let controller = self?.largeTypeWindowController else { throw CancellationError() }
                    try controller.activatePreparedWindow(prepared)
                },
                present: { [weak self] prepared in
                    guard let controller = self?.largeTypeWindowController else { throw CancellationError() }
                    try controller.present(prepared)
                },
                complete: { [weak self] prepared in self?.largeTypeWindowController?.completePresentation(prepared) },
                discard: { [weak self] prepared in self?.largeTypeWindowController?.discard(prepared) }
            )
        )

        guard let viewModel else { return }

        configureQuickAccessPanel(viewModel: viewModel)
    }

    private func configureQuickAccessPanel(viewModel: QuickAccessViewModel) {
        syncIssueWindowController = SyncIssueWindowController(actions: .init(
            copyReport: { [weak viewModel] presentation in
                viewModel?.copySyncIssueReport(presentation)
            },
            copyAndReport: { [weak viewModel] presentation in
                viewModel?.copyAndReportSyncIssue(presentation)
            },
            copySkippedItemCommand: { [weak viewModel] item in
                viewModel?.copySkippedSyncItemInspectCommand(item)
            },
            dismissIssue: { [weak viewModel] presentation in
                viewModel?.dismissSyncIssue(presentation)
            }
        ))

        let quickAccessView = QuickAccessView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.panelController?.hide() },
            appDelegate: self
        )
        panelController?.setContent(quickAccessView)
        panelController?.onShow = { [weak self] in
            self?.viewModel?.cancelSearchClear()
            self?.requestSearchFocusIfNeeded()
            self?.scheduleAutoUnlockIfNeeded()
        }
        panelController?.onHide = { [weak self] in
            self?.viewModel?.scheduleSearchClear()
            self?.autoUnlockToken = nil
            self?.panelShownForLockWait = false
        }
        panelController?.shouldBlockHide = { [weak self] in
            self?.isUnlockInFlight ?? false
        }
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
            onLoginPassCLI: {
                NotificationCenter.default.post(name: .passCLILoginRequested, object: nil)
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

        passCLILoginObserver = NotificationCenter.default.addObserver(
            forName: .passCLILoginRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.passCLILoginCoordinator?.startLogin()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.handleWindowDidBecomeKeyNotification(notification)
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
                let cliSelectionChanged = self?.applyCLISelectionPreference() ?? false
                await self?.sshCoordinator?.reconcile()
                await self?.runCoordinator?.reconcile()
                if cliSelectionChanged {
                    await self?.healthCoordinator?.refreshAll()
                }
            }
        }
    }

    /// Pushes the current Pass CLI source preference into `cliService`, returning
    /// true iff the resolved path changed. Sequencing matters: coordinators
    /// and the health probe must observe the new value, so this runs before
    /// reconcile() + refreshAll() in the UserDefaults change observer.
    func applyCLISelectionPreference() -> Bool {
        guard let cliService else { return false }
        let customPath = UserDefaults.standard.string(forKey: DefaultsKey.cliPath)
        let rawSelection = UserDefaults.standard.string(forKey: DefaultsKey.passCLISelection)
        let preference = PassCLISelectionPreference.resolved(
            rawValue: rawSelection,
            legacyCustomPath: customPath
        )
        return cliService.updateCLISelection(
            preference: preference,
            customPath: customPath?.isEmpty == false ? customPath : nil
        )
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
