import Foundation

@MainActor
private struct AppPassCLIHealthRefresher: PassCLIHealthRefreshing {
    weak var appDelegate: AppDelegate?

    func refreshPassCLIHealth() async -> PassCLIHealth {
        await appDelegate?.healthCoordinator?.refreshPassCLI()
            ?? .failed(reason: "Health refresh unavailable")
    }
}

extension AppDelegate {
    func setupCoordinators() {
        notificationRouter = UserNotificationRouter()

        syncCoordinator = SyncCoordinator(
            cliService: cliService!,
            databaseManager: databaseManager!,
            viewModel: viewModel!,
            identitySynchronizer: AutoFillIdentitySynchronizer(
                adapter: ASCredentialIdentityStoreAdapter()
            ),
            offlineModeService: offlineModeService,
            maintenance: offlineStorageMaintenance,
            onResetInitiated: { [weak self] in self?.revokeTransientSecretAccess() },
            onSyncIssueChanged: { [weak self] presentation in
                self?.syncIssueDidChange(presentation)
            },
            onAuthenticationRequired: { [weak self] health in
                await self?.healthCoordinator?.reportAuthenticationFailure(health: health)
            }
        )
        syncCoordinator?.start()

        if let cliService {
            setupPassCLIAuthenticationCoordinators(cliService: cliService)
        }

        let authCallbacks = AuthDialogHelper.Callbacks(
            onAuthSuccess: { [weak self] in self?.resetAuthTimestamp() },
            onBiometryLockout: { [weak self] in self?.forceLock() }
        )

        sshCoordinator = makeSSHCoordinator(authCallbacks: authCallbacks)
        wireLockClosures(on: sshCoordinator)

        runCoordinator = makeRunCoordinator(authCallbacks: authCallbacks)
        wireLockClosures(on: runCoordinator)

        setupAutoFillBroker()

        if let cliService, let runCoordinator, let sshCoordinator {
            healthCoordinator = HealthCheckCoordinator(
                cliStore: passCLIStatusStore,
                cliService: cliService,
                cliChecker: LivePassCLIHealthChecker(),
                runChecker: LiveRunProbeChecker(),
                sshChecker: LiveSSHProbeChecker(),
                runCoordinator: runCoordinator,
                sshCoordinator: sshCoordinator,
                passCLITransitionHandler: passCLIPATAutoLoginCoordinator ?? passCLILoginNotifier
            )
        }
    }

    func setupPassCLIAuthenticationCoordinators(
        cliService: PassCLIService,
        notificationPoster: any PassCLILoginNotificationPosting = LivePassCLILoginNotificationPoster(),
        requestsAuthorization: Bool = true
    ) {
        let loginCoordinator = PassCLILoginCoordinator(
            sessionMutationGate: passCLISessionMutationGate,
            cliService: cliService,
            currentHealth: { [weak self] in self?.passCLIStatusStore.health ?? .notInstalled },
            healthRefresher: AppPassCLIHealthRefresher(appDelegate: self),
            syncTrigger: { [weak self] in self?.syncCoordinator?.refreshNow() },
            resultHandler: { [weak self] result in self?.handlePassCLIBrowserLoginResult(result) },
            revokeTransientSecretAccess: { [weak self] in self?.revokeTransientSecretAccess() }
        )
        passCLILoginCoordinator = loginCoordinator

        let loginNotifier = PassCLILoginNotifier(
            notificationRouter: notificationRouter,
            poster: notificationPoster,
            startLogin: { [weak self] in self?.requestPassCLILogin() },
            showLoginRequired: { [weak self] in
                self?.showLoginRequiredSyncIssue()
            },
            clearLoginRequired: { [weak self] in
                self?.clearLoginRequiredSyncIssue()
            }
        )
        if requestsAuthorization {
            loginNotifier.requestAuthorizationIfNeeded()
        }
        passCLILoginNotifier = loginNotifier
        passCLIRecommendedVersionNotifier = PassCLIRecommendedVersionNotifier()

        setupPassCLIPATCoordinators(
            cliService: cliService,
            loginNotifier: loginNotifier
        )
    }

    private func setupPassCLIPATCoordinators(
        cliService: PassCLIService,
        loginNotifier: PassCLILoginNotifier
    ) {
        let patCredentialStore = KeychainPassCLIPATCredentialStore()
        passCLIPATCredentialStore = patCredentialStore

        let patLoginService = PassCLIPATLoginService(
            sessionMutationGate: passCLISessionMutationGate,
            credentialStore: patCredentialStore,
            cliService: cliService,
            healthRefresher: AppPassCLIHealthRefresher(appDelegate: self),
            syncTrigger: { [weak self] in self?.syncCoordinator?.refreshNow() },
            revokeTransientSecretAccess: { [weak self] in self?.revokeTransientSecretAccess() }
        )
        passCLIPATLoginService = patLoginService

        passCLIPATSettingsModel = PassCLIPATSettingsModel(
            sessionMutationGate: passCLISessionMutationGate,
            credentialStore: patCredentialStore,
            loginWithSavedToken: { [weak patLoginService] lease in
                await patLoginService?.loginWithSavedToken(lease: lease)
                    ?? .failed(String(localized: "Personal access token login is unavailable."))
            },
            invalidPATHandler: { [weak self] message in
                self?.showInvalidPATSyncIssue(userFacingMessage: message)
            },
            isCurrentSessionPersonalAccessToken: { [weak self] in
                self?.passCLIStatusStore.identity?.isPersonalAccessTokenSession == true
            },
            logoutFromPassCLI: { [weak self] lease in
                guard let self else { return }
                try await self.logoutFromPassCLI(
                    cliService: cliService,
                    offlineModeService: self.offlineModeService,
                    lease: lease
                )
            }
        )

        passCLIPATAutoLoginCoordinator = PassCLIPATAutoLoginCoordinator(
            credentialStore: patCredentialStore,
            sessionMutationGate: passCLISessionMutationGate,
            currentHealth: { [weak self] in self?.passCLIStatusStore.health ?? .notInstalled },
            loginWithSavedToken: { [weak patLoginService] lease in
                await patLoginService?.loginWithSavedToken(lease: lease)
                    ?? .failed(String(localized: "Personal access token login is unavailable."))
            },
            fallbackHandler: loginNotifier,
            patFailureHandler: { [weak loginNotifier] message in
                loginNotifier?.handlePATLoginFailure(message)
            },
            invalidPATHandler: { [weak self] message in
                self?.showInvalidPATSyncIssue(userFacingMessage: message)
            },
            autoLoginStartedHandler: { [weak self] in
                self?.showPATAutoLoginSyncProgress()
            }
        )
    }

    /// Revokes transient presentation before the logout process can suspend.
    func logoutFromPassCLI(
        cliService: PassCLIService,
        offlineModeService: OfflineModeService?,
        lease callerLease: PassCLISessionMutationGate.Lease? = nil
    ) async throws {
        guard let lease = callerLease ?? passCLISessionMutationGate.tryAcquire(.logout),
              lease.operation == .logout, passCLISessionMutationGate.owns(lease) else {
            throw PassCLISessionMutationGate.AdmissionError.busy
        }
        defer { if callerLease == nil { passCLISessionMutationGate.release(lease) } }
        try Task.checkCancellation()
        revokeTransientSecretAccess()
        try await Self.logoutFromPassCLI(cliService: cliService, offlineModeService: offlineModeService)
    }

    /// Purges host-only offline data only after Pass CLI confirms logout.
    static func logoutFromPassCLI(
        cliService: PassCLIService,
        offlineModeService: OfflineModeService?
    ) async throws {
        try await cliService.logout()
        try await offlineModeService?.removeAllOfflineData()
    }

    func setupWakeObserver() {
        wakeObserver = WakeObserver { [weak self] in
            await self?.healthCoordinator?.handleSystemWake()
        }
        wakeObserver?.start()
    }

    func setupSystemLockObserver() {
        systemLockObserver = SystemLockObserver { [weak self] in
            self?.handleSystemLockEvent()
        }
        systemLockObserver?.start()
    }

    func runLaunchTimeSanityCheck() {
        Task { [weak self] in
            await self?.healthCoordinator?.start()
            self?.passCLIRecommendedVersionNotifier?.postStartupWarningIfNeeded(
                self?.passCLIStatusStore.recommendedVersionWarning
            )
        }
    }

    func makeSSHCoordinator(authCallbacks: AuthDialogHelper.Callbacks) -> SSHProxyCoordinator {
        let coordinator = SSHProxyCoordinator(
            cliService: cliService!,
            databaseManager: databaseManager!,
            onError: { [weak self] message in self?.viewModel?.errorMessage = message },
            healthStore: healthStore,
            keychainService: keychainService!,
            passCLIStatusStore: passCLIStatusStore,
            terminalHostStore: terminalHostStore,
            paneDetailsProvider: herdrPaneDetailsProvider,
            authCallbacks: authCallbacks,
            notificationRouter: notificationRouter
        )
        coordinator.setup()
        return coordinator
    }

    func setupAutoFillBroker() {
        guard let databaseManager,
              let keychainService,
              let offlineSecretResolver,
              let databaseURL = autoFillDatabaseURL,
              let socketPath = autoFillSocketPath else {
            return
        }

        let registry = autoFillRequestRegistry
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: AutoFillDescriptorStore(
                databaseURL: databaseURL,
                keychainService: keychainService
            ),
            associationStore: AutoFillAppAssociationStore(databaseManager: databaseManager),
            secretResolver: OfflineAutoFillSecretResolver(resolver: offlineSecretResolver),
            secretReleaseGuard: secretReleaseGuard,
            isAppLocked: { [weak self] in self?.isLocked ?? false },
            showLockedPanel: { [weak self] remainingSeconds in
                await self?.showPanelAndWaitForUnlock(timeoutSeconds: remainingSeconds) ?? false
            },
            accessibility: LiveAutoFillAccessibilityAdapter(
                recoverFocus: { [weak self] in self?.requestUnlockAccessibilityFocus() }
            )
        )
        let broker = AutoFillBroker(
            listenPath: socketPath,
            registry: registry,
            launchGate: autoFillLaunchGate,
            requestHandler: { request, transition, appAssociationIntent in
                try await coordinator.resolveDelivery(
                    request: request,
                    appAssociationIntent: appAssociationIntent,
                    transition: transition
                )
            },
            candidateHandler: { query in
                try await coordinator.listCandidates(query: query)
            }
        )

        autoFillBrokerCoordinator = coordinator
        autoFillBroker = broker
        let gate = autoFillLaunchGate
        autoFillBrokerStartTask = Task { [weak self] in
            do {
                while gate.beginBrokerStart() == false {
                    for registration in gate.drainStartupRegistrations() {
                        try? await registry.registerWake(
                            handle: registration.handle,
                            deadline: registration.deadline
                        )
                    }
                }
                try await broker.start()
                gate.markListenerReady()
            } catch is CancellationError {
                return
            } catch {
                self?.viewModel?.errorMessage = String(localized: "Failed to start AutoFill broker.")
            }
        }
    }

    func makeRunCoordinator(authCallbacks: AuthDialogHelper.Callbacks) -> RunProxyCoordinator {
        let coordinator = RunProxyCoordinator(
            cliService: cliService!,
            databaseManager: databaseManager!,
            onError: { [weak self] message in self?.viewModel?.errorMessage = message },
            healthStore: healthStore,
            passCLIStatusStore: passCLIStatusStore,
            keychainService: keychainService!,
            terminalHostStore: terminalHostStore,
            paneDetailsProvider: herdrPaneDetailsProvider,
            authCallbacks: authCallbacks
        )
        coordinator.setup()
        return coordinator
    }

    /// Wires the four lock-lifecycle closures onto an SSH coordinator.
    /// `?? UUID()` is unreachable in practice: AppDelegate lives for the
    /// whole process. It satisfies the non-optional return type when the
    /// compiler cannot prove liveness through `[weak self]`.
    func wireLockClosures(on coordinator: SSHProxyCoordinator?) {
        coordinator?.isAppLocked = { [weak self] in self?.isLocked ?? false }
        coordinator?.showLockedPanel = { [weak self] in
            await self?.showPanelAndWaitForUnlock() ?? false
        }
        coordinator?.setPendingLockContext = { [weak self] context in
            self?.setPendingLockContext(context) ?? UUID()
        }
        coordinator?.clearPendingLockContext = { [weak self] token in
            self?.clearPendingLockContext(token: token)
        }
    }

    func wireLockClosures(on coordinator: RunProxyCoordinator?) {
        coordinator?.isAppLocked = { [weak self] in self?.isLocked ?? false }
        coordinator?.showLockedPanel = { [weak self] in
            await self?.showPanelAndWaitForUnlock() ?? false
        }
        coordinator?.setPendingLockContext = { [weak self] context in
            self?.setPendingLockContext(context) ?? UUID()
        }
        coordinator?.clearPendingLockContext = { [weak self] token in
            self?.clearPendingLockContext(token: token)
        }
    }
}
