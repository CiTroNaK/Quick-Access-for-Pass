import AppKit
import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Quick Access offline actions", .timeLimit(.minutes(1)))
struct QuickAccessViewModelOfflineActionTests {
    @Test @MainActor func removedFieldCannotReachLargeTypeAfterResolverReturn() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        var item = try #require(fixture.items.first)
        item.fieldKeys = [.email]
        let service = fixture.service(viewer: FieldSnapshotViewer())
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let gate = OfflineTestGate()
        let controller = LargeTypeWindowController(presentationMode: .headless)
        var shown = 0
        controller.onWindowShown = { _ in shown += 1 }
        let vm = QuickAccessViewModel(searchService: SearchService(databaseManager: fixture.database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {},
            secretResolver: RetainedFieldResolver(resolver: OfflineSecretResolver(live: UnavailableLiveRecorder(),
                repository: fixture.repository, codec: fixture.codec(), readiness: service), gate: gate),
            largeTypePresentation: headlessLargeTypeActions(controller: controller))
        vm.detailItem = item
        vm.selectedRowIndex = try #require(vm.rows(for: item).firstIndex(where: { if case .field(.email, _, _) = $0 { true } else { false } }))
        vm.showSelectedRowInLargeType()
        try await gate.waitUntilEntered()
        let task = try #require(vm.inFlightLargeType)
        try await fixture.repository.removeItem(item.id)
        await gate.open()
        await task.value
        #expect(shown == 0)
        #expect(controller.debugWindow == nil)
        #expect(controller.debugHostingController == nil)
    }

    @Test("Large Type phase callbacks reenter outside authority synchronization", arguments: ["prepared", "activation", "shown", "lifecycle", "cancel"])
    @MainActor func phaseCallbacksAreOutsideRelease(phase: String) async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let resolved = try await OfflineSecretResolver(live: UnavailableLiveRecorder(), repository: fixture.repository,
            codec: fixture.codec(), readiness: service).resolveItem(itemId: item.id, vaultId: item.vaultId, shareId: "share")
        let controller = LargeTypeWindowController(presentationMode: .headless)
        let guardState = SecretReleaseGuard()
        var events: [String] = []
        var vm: QuickAccessViewModel?
        controller.onWindowPrepared = { window in
            events.append("prepare")
            #expect(window.contentViewController == nil)
            if phase == "prepared" { try! fixture.database.syncItems([]) }
        }
        controller.onPreparationDiscarded = { window in
            events.append("discard")
            #expect(window.contentViewController == nil)
        }
        controller.onWindowShown = { _ in
            events.append("shown")
            if phase == "shown" { try! fixture.database.syncItems([]) }
        }
        let actions = LargeTypePresentationActions(
            prepare: { controller.prepare(display: $0, relativeTo: nil) },
            activate: { prepared in
                events.append("activate")
                #expect(prepared.window.contentViewController == nil)
                try controller.activatePreparedWindow(prepared)
                if phase == "activation" { try fixture.database.syncItems([]) }
                if phase == "lifecycle" { guardState.revoke() }
                if phase == "cancel" { vm?.cancelSecretActions() }
            },
            present: { prepared in
                events.append("present")
                try controller.present(prepared)
            },
            complete: { controller.completePresentation($0) },
            discard: { controller.discard($0) }
        )
        vm = QuickAccessViewModel(searchService: SearchService(databaseManager: fixture.database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {},
            secretResolver: FixedResolvedItemResolver(item: resolved), secretReleaseGuard: guardState, largeTypePresentation: actions)
        let viewModel = try #require(vm)
        viewModel.detailItem = item
        viewModel.selectedRowIndex = 1
        viewModel.showSelectedRowInLargeType()
        let task = try #require(viewModel.inFlightLargeType)
        await task.value
        if phase == "shown" {
            #expect(events == ["prepare", "activate", "present", "shown"])
            #expect(controller.debugHostingController != nil) // Already released, not recalled.
            #expect(throws: OfflineReleaseError.revoked) {
                try resolved.map { _ in "obsolete" }.release(validating: {}, effect: { _ in Issue.record("released twice") })
            }
        } else {
            #expect(events == ["prepare", "activate", "discard"])
            #expect(controller.debugWindow == nil)
        }
        #expect(viewModel.inFlightLargeType == nil)
        controller.close()
    }

    @Test @MainActor func revokedReuseDiscardsOnlyUnattachedNewContent() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let controller = LargeTypeWindowController(presentationMode: .headless)
        controller.show(display: try LargeTypeDisplay(validating: "PREVIOUS"), relativeTo: nil)
        let previousWindow = try #require(controller.debugWindow)
        let previousContent = try #require(previousWindow.contentViewController)
        var unregistered = 0
        var completed = 0
        controller.onPreparationDiscarded = { _ in unregistered += 1 }
        controller.onWindowShown = { _ in completed += 1 }
        let actions = LargeTypePresentationActions(
            prepare: { controller.prepare(display: $0, relativeTo: nil) },
            activate: { prepared in
                #expect(prepared.window === previousWindow)
                #expect(prepared.window.contentViewController === previousContent)
                try controller.activatePreparedWindow(prepared)
                try fixture.database.syncItems([])
            },
            present: { try controller.present($0) },
            complete: { controller.completePresentation($0) },
            discard: { controller.discard($0) }
        )
        let vm = QuickAccessViewModel(searchService: SearchService(databaseManager: fixture.database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {},
            secretResolver: OfflineSecretResolver(live: UnavailableLiveRecorder(), repository: fixture.repository,
                codec: fixture.codec(), readiness: service), largeTypePresentation: actions)
        vm.detailItem = item
        vm.selectedRowIndex = 1
        vm.showSelectedRowInLargeType()
        await vm.inFlightLargeType?.value
        #expect(controller.debugWindow === previousWindow)
        #expect(previousWindow.contentViewController === previousContent)
        #expect(unregistered == 0)
        #expect(completed == 0)
        controller.close()
    }

    @Test @MainActor func missingLargeTypeDriverFailsClosedAndStillSupersedesCopy() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let gate = OfflineTestGate()
        let vm = QuickAccessViewModel(searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {},
            secretResolver: ActionGateResolver(gate: gate))
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        vm.handleAction(.copyPassword, for: item)
        try await gate.waitUntilEntered()
        let old = try #require(vm.inFlightCopy)
        vm.detailItem = item
        vm.selectedRowIndex = 1
        vm.showSelectedRowInLargeType()
        let current = try #require(vm.inFlightLargeType)
        await gate.open()
        await old.value
        await current.value
        #expect(vm.inFlightCopy == nil)
        #expect(vm.inFlightLargeType == nil)
        #expect(vm.clipboardManager.lastCopiedValue == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test @MainActor func repositoryRemovalAfterFieldResolutionPreventsPasteboardEffect() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service(viewer: FieldSnapshotViewer())
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let gate = OfflineTestGate()
        let pasteboard = NSPasteboard(name: .init("task3-field-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: pasteboard)
        let resolver = OfflineSecretResolver(live: UnavailableLiveRecorder(), repository: fixture.repository, codec: fixture.codec(), readiness: service)
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: fixture.database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: RetainedFieldResolver(resolver: resolver, gate: gate)
        )
        viewModel.copyField(.email, from: item)
        try await gate.waitUntilEntered()
        let task = try #require(viewModel.inFlightCopy)
        try await fixture.repository.removeItem(item.id)
        await gate.open()
        await task.value
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(clipboard.lastCopiedValue == nil)
    }

    @Test @MainActor func staleOfflineRemovalUsesUnifiedRepository() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await service.makeAvailableOffline(item: item, shareId: "share")
        try OfflineCatalogFixtureSupport.updateCacheStatus(in: fixture.database, itemId: item.id, status: .failed, refreshedAt: .distantPast)
        let observation = OfflineCatalogObservation(database: fixture.database)
        var iterator = observation.snapshots().makeAsyncIterator()
        let coordinator = OfflineModeCoordinator(
            service: service,
            observation: observation,
            shareIDForVault: { _ in "share" }
        )
        coordinator.apply(try #require(try await iterator.next()))
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: fixture.database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {}, offlineModeCoordinator: coordinator
        )

        #expect(coordinator.availability(for: item) == .stale(lastRefreshedAt: .distantPast))
        viewModel.handleOfflineAvailability(for: item)
        await viewModel.inFlightOfflineOperation?.value
        #expect(try await fixture.repository.authorizedSnapshot(for: OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)) == nil)
    }

    @Test @MainActor func copyCompletionDoesNotClearBusyWhileOfflineOperationWaits() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        let gate = NonCancellableOfflineActionGate()
        let coordinator = OfflineModeCoordinator(service: LateFailingOfflineActionService(gate: gate),
            observation: ActionObservation(snapshot: .empty), shareIDForVault: { _ in "share" })
        await coordinator.startObservation().value
        let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName())
        let vm = QuickAccessViewModel(searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: ActionResolver(), offlineModeCoordinator: coordinator)
        vm.detailItem = item
        vm.handleOfflineAvailability(for: item)
        try await gate.waitUntilEntered()
        let offlineTask = try #require(vm.inFlightOfflineOperation)
        vm.handleAction(.copyPassword, for: item)
        await vm.inFlightCopy?.value
        #expect(clipboard.lastCopiedValue == "offline-password")
        #expect(vm.isActionLoading)
        await gate.open()
        await offlineTask.value
        #expect(!vm.isActionLoading)
    }

    @Test @MainActor func largeTypeCompletionDoesNotClearBusyWhileOfflineOperationWaits() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        let gate = NonCancellableOfflineActionGate()
        let coordinator = OfflineModeCoordinator(service: LateFailingOfflineActionService(gate: gate),
            observation: ActionObservation(snapshot: .empty), shareIDForVault: { _ in "share" })
        await coordinator.startObservation().value
        let controller = LargeTypeWindowController(presentationMode: .headless)
        let vm = QuickAccessViewModel(searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {},
            secretResolver: ActionResolver(), offlineModeCoordinator: coordinator,
            largeTypePresentation: headlessLargeTypeActions(controller: controller))
        vm.detailItem = item
        vm.handleOfflineAvailability(for: item)
        try await gate.waitUntilEntered()
        let offlineTask = try #require(vm.inFlightOfflineOperation)
        vm.selectedRowIndex = 1
        vm.showSelectedRowInLargeType()
        await vm.inFlightLargeType?.value
        #expect(controller.debugHostingController != nil)
        #expect(vm.isActionLoading)
        await gate.open()
        await offlineTask.value
        #expect(!vm.isActionLoading)
        controller.close()
    }

    @Test @MainActor func lateAdmissionFailureAfterHideDoesNotPublishStaleError() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        let gate = NonCancellableOfflineActionGate()
        let service = LateFailingOfflineActionService(gate: gate)
        let coordinator = OfflineModeCoordinator(
            service: service,
            observation: ActionObservation(snapshot: .empty),
            shareIDForVault: { _ in "share" }
        )
        await coordinator.startObservation().value
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {}, offlineModeCoordinator: coordinator
        )
        viewModel.detailItem = item
        viewModel.handleOfflineAvailability(for: item)
        try await gate.waitUntilEntered()
        let action = try #require(viewModel.inFlightOfflineOperation)
        viewModel.hideDetail()
        await gate.open()
        await action.value
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor func releaseTokenIsRevokedWithoutNewAuthenticationPolicy() {
        let guardState = SecretReleaseGuard()
        let token = guardState.capture()
        guardState.revoke()
        #expect(!guardState.isCurrent(token))
        #expect(guardState.isCurrent(guardState.capture()))
    }

    @Test @MainActor func revokedActionDoesNotCopyOrPresentLargeTypeAfterResolution() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let guardState = SecretReleaseGuard()
        let gate = OfflineTestGate()
        let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName())
        var presented = false
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: ActionGateResolver(gate: gate),
            secretReleaseGuard: guardState,
            largeTypePresentation: headlessLargeTypeActions(onPresented: { _ in presented = true })
        )
        viewModel.detailItem = item
        viewModel.selectedRowIndex = 1
        viewModel.showSelectedRowInLargeType()
        do {
            try await gate.waitUntilEntered()
            let task = try #require(viewModel.inFlightLargeType)
            guardState.revoke()
            viewModel.cancelSecretActions()
            await gate.open()
            await task.value
            #expect(clipboard.lastCopiedValue == nil)
            #expect(presented == false)
        } catch {
            await gate.open()
            throw error
        }
    }

    @Test @MainActor func offlineUnavailableAndSecretCommandErrorsAreSafeForCopyPresentation() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName())
        let unavailable = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: UnavailableActionResolver()
        )
        unavailable.handleAction(.copyPassword, for: item)
        await unavailable.inFlightCopy?.value
        #expect(unavailable.errorMessage == String(localized: "Not available offline. Sign in to Proton Pass or reconnect, then try again."))
        #expect(clipboard.lastCopiedValue == nil)
        unavailable.handleAction(.copyTotp, for: item)
        await unavailable.inFlightCopy?.value
        #expect(unavailable.errorMessage == String(localized: "Not available offline. Sign in to Proton Pass or reconnect, then try again."))
        unavailable.copyField(.email, from: item)
        await unavailable.inFlightCopy?.value
        #expect(unavailable.errorMessage == String(localized: "Not available offline. Sign in to Proton Pass or reconnect, then try again."))
        unavailable.detailItem = item
        unavailable.selectedRowIndex = 1
        unavailable.showSelectedRowInLargeType()
        await unavailable.inFlightLargeType?.value
        #expect(unavailable.errorMessage == String(localized: "Not available offline. Sign in to Proton Pass or reconnect, then try again."))

        let commandFailure = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {}, secretResolver: SensitiveFailureActionResolver()
        )
        commandFailure.handleAction(.copyPassword, for: item)
        await commandFailure.inFlightCopy?.value
        #expect(!(commandFailure.errorMessage ?? "").contains("<<TASK7_SECRET_MARKER>>"))
        commandFailure.handleAction(.copyTotp, for: item)
        await commandFailure.inFlightCopy?.value
        #expect(!(commandFailure.errorMessage ?? "").contains("<<TASK7_SECRET_MARKER>>"))
        commandFailure.copyField(.email, from: item)
        await commandFailure.inFlightCopy?.value
        #expect(!(commandFailure.errorMessage ?? "").contains("<<TASK7_SECRET_MARKER>>"))
        commandFailure.detailItem = item
        commandFailure.selectedRowIndex = 1
        commandFailure.showSelectedRowInLargeType()
        await commandFailure.inFlightLargeType?.value
        #expect(!(commandFailure.errorMessage ?? "").contains("<<TASK7_SECRET_MARKER>>"))
    }

    @Test @MainActor func manualOnlySnapshotFallbackReachesHostCopyAndLargeType() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        #expect(try await fixture.repository.offlineVaultIds().isEmpty)
        let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName())
        var displayedValue: String?
        let live = UnavailableLiveRecorder()
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: fixture.codec(), readiness: service
        )
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: fixture.database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: resolver,
            largeTypePresentation: headlessLargeTypeActions(onPresented: { displayedValue = $0.value })
        )

        viewModel.handleAction(.copyPassword, for: item)
        await viewModel.inFlightCopy?.value
        #expect(clipboard.lastCopiedValue == "fake-password")
        #expect(await live.itemCallCount() == 1)

        viewModel.detailItem = item
        viewModel.selectedRowIndex = 1
        viewModel.showSelectedRowInLargeType()
        await viewModel.inFlightLargeType?.value
        #expect(displayedValue == "fake-password")
        #expect(await live.itemCallCount() == 2)
    }

    @Test @MainActor func authenticatedDecoderMarkerUsesSafeUIAndNoDiagnostics() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let codec = fixture.codec()
        let service = OfflineModeService(repository: fixture.repository, codec: codec, cliService: OfflineFixtureViewer())
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let marker = "<<TASK7_DECODER_UI_MARKER>>"
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let payload = try cipher.seal(Data("malformed-\(marker)".utf8), for: snapshot.identity)
        try await fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE offlineSnapshots SET encryptedPayload = ? WHERE vaultId = ? AND itemId = ?",
                arguments: [payload, "vault", "item"]
            )
        }
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: fixture.database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {},
            secretResolver: OfflineSecretResolver(
                live: DecoderMarkerLive(), repository: fixture.repository, codec: codec, readiness: service
            )
        )
        viewModel.handleAction(.copyPassword, for: item)
        await viewModel.inFlightCopy?.value

        #expect(viewModel.errorMessage == String(localized: "Not available offline. Sign in to Proton Pass or reconnect, then try again."))
        #expect(viewModel.lastCommand.contains(marker) == false)
        #expect((viewModel.errorMessage ?? "").contains(marker) == false)
        #expect(viewModel.currentSyncDiagnosticsPresentation == nil)
    }

    @Test @MainActor func revocationStopsPasswordTOTPAndFieldReleases() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let item = offlineTestMetadata(id: "item", vaultID: "vault")

        for action in [ItemAction.copyPassword, .copyTotp] {
            let guardState = SecretReleaseGuard()
            let gate = OfflineTestGate()
            let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName())
            let viewModel = QuickAccessViewModel(
                searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
                clipboardManager: clipboard, onDismiss: {}, secretResolver: ActionGateResolver(gate: gate),
                secretReleaseGuard: guardState
            )
            viewModel.handleAction(action, for: item)
            try await gate.waitUntilEntered()
            let task = try #require(viewModel.inFlightCopy)
            guardState.revoke()
            viewModel.cancelSecretActions()
            await gate.open()
            await task.value
            #expect(clipboard.lastCopiedValue == nil)
        }

        let guardState = SecretReleaseGuard()
        let gate = OfflineTestGate()
        let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName())
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: ActionGateResolver(gate: gate),
            secretReleaseGuard: guardState
        )
        viewModel.copyField(.email, from: item)
        try await gate.waitUntilEntered()
        let task = try #require(viewModel.inFlightCopy)
        guardState.revoke()
        viewModel.cancelSecretActions()
        await gate.open()
        await task.value
        #expect(clipboard.lastCopiedValue == nil)
    }

    @Test @MainActor func staleActionCannotClearTheNewerActionErrorOrSpinner() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let gate = OfflineTestGate()
        let resolver = OldActionResolver(gate: gate)
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {}, secretResolver: resolver
        )
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        viewModel.handleAction(.copyPassword, for: item)
        try await gate.waitUntilEntered()
        let oldTask = try #require(viewModel.inFlightCopy)
        viewModel.handleAction(.copyPassword, for: item)
        let newTask = try #require(viewModel.inFlightCopy)
        await newTask.value
        await gate.open()
        await oldTask.value

        #expect(viewModel.errorMessage == String(localized: "Failed to copy secret"))
        #expect(viewModel.isActionLoading == false)
    }

    @Test @MainActor func staleLargeTypeCannotClearSupersedingCopyHandle() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let largeTypeGate = OfflineTestGate()
        let copyGate = OfflineTestGate()
        let resolver = SequencedActionGateResolver(gates: [largeTypeGate, copyGate])
        let vm = QuickAccessViewModel(searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName()), onDismiss: {},
            secretResolver: resolver,
            largeTypePresentation: headlessLargeTypeActions())
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        vm.detailItem = item
        vm.selectedRowIndex = 1
        vm.showSelectedRowInLargeType()
        try await largeTypeGate.waitUntilEntered()
        let oldLargeType = try #require(vm.inFlightLargeType)
        vm.handleAction(.copyPassword, for: item)
        try await copyGate.waitUntilEntered()
        let currentCopy = try #require(vm.inFlightCopy)
        await largeTypeGate.open()
        await oldLargeType.value
        #expect(vm.inFlightCopy != nil)
        #expect(vm.isActionLoading)
        await copyGate.open()
        await currentCopy.value
        #expect(vm.inFlightCopy == nil)
        #expect(!vm.isActionLoading)
    }

    @Test @MainActor func copyPasswordUsesInjectedSecretResolver() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: .withUniqueName())
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: ActionResolver()
        )
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        viewModel.handleAction(.copyPassword, for: item)
        await viewModel.inFlightCopy?.value
        #expect(clipboard.lastCopiedValue == "offline-password")
    }
}

private actor SequencedActionGateResolver: SecretItemResolving {
    private let gates: [OfflineTestGate]
    private var nextGate = 0

    init(gates: [OfflineTestGate]) { self.gates = gates }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        let gate = gates[nextGate]
        nextGate += 1
        try await gate.wait()
        return ResolvedSecret(value: try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "gated"), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        throw CancellationError()
    }
}

private actor ActionGateResolver: SecretItemResolving {
    private let gate: OfflineTestGate

    init(gate: OfflineTestGate) { self.gate = gate }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        try? await gate.wait()
        return ResolvedSecret(value: try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "not-released"), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        try? await gate.wait()
        return ResolvedSecret(value: "000000", offlineCapability: nil)
    }
}

private struct DecoderMarkerLive: OfflineSecretResolvingLive {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.notLoggedIn }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.notLoggedIn }
}

private struct UnavailableActionResolver: SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        throw OfflineSecretResolver.Error.unavailable
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        throw OfflineSecretResolver.Error.unavailable
    }
}

private struct SensitiveFailureActionResolver: SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        throw CLIError.commandFailed("<<TASK7_SECRET_MARKER>>")
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        throw CLIError.commandFailed("<<TASK7_SECRET_MARKER>>")
    }
}

private actor OldActionResolver: SecretItemResolving {
    private let gate: OfflineTestGate
    private var itemCalls = 0

    init(gate: OfflineTestGate) { self.gate = gate }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        itemCalls += 1
        if itemCalls == 1 {
            try? await gate.wait()
            return ResolvedSecret(value: try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "stale"), offlineCapability: nil)
        }
        throw CLIError.commandFailed("new-action-failure")
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        return ResolvedSecret(value: "000000", offlineCapability: nil)
    }
}

private struct ActionObservation: OfflineCatalogObserving {
    let snapshot: OfflinePresentationSnapshot

    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
}

private actor LateFailingOfflineActionService: OfflineModeServicing {
    private let gate: NonCancellableOfflineActionGate

    init(gate: NonCancellableOfflineActionGate) { self.gate = gate }
    func initialize() async throws {}
    func requiresInitializationRetry() async -> Bool { false }
    func isReady() async -> Bool { true }
    func makeAvailableOffline(item: PassItem, shareId: String) async throws {
        await gate.wait()
        throw OfflineModeService.Error.selectionSuspended
    }
    func removeOfflineItem(itemId: String) async throws {}
    func selectWholeVault(_ selected: Bool, vaultID: String) async throws {}
    func updateSelectionObservation(generation: UUID, status: OfflineSelectionObservationStatus) async {}
    func keepOfflineIndividually(_ item: PassItem) async throws {}
    func retrySelectedCopies(vaultID: String?) async throws {}
    func metadataDidSynchronize(allowMembershipExpansion: Bool, eligibleItemIDs: Set<String>) async {}
    func waitUntilIdle() async {}
    func prepareForMetadataReset() async throws {}
    func finishMetadataReset() async {}
    func stop() async {}
    func removeAllOfflineData() async throws {}
}

private actor NonCancellableOfflineActionGate {
    private var entered = false
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilEntered() async throws {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private actor UnavailableLiveRecorder: OfflineSecretResolvingLive {
    private(set) var itemCalls = 0

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        itemCalls += 1
        throw CLIError.notLoggedIn
    }

    func getTotp(itemId: String, shareId: String) async throws -> String {
        itemCalls += 1
        throw CLIError.notLoggedIn
    }

    func itemCallCount() -> Int { itemCalls }

    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem {
        try await viewItem(itemId: itemId, shareId: shareId)
    }

    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String {
        try await getTotp(itemId: itemId, shareId: shareId)
    }
}

private struct ActionResolver: SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        return ResolvedSecret(value: try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "offline-password"), offlineCapability: nil)
    }
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        return ResolvedSecret(value: "000000", offlineCapability: nil)
    }
}

private struct RetainedFieldResolver: SecretItemResolving {
    let resolver: any SecretItemResolving
    let gate: OfflineTestGate
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        let result = try await resolver.resolveItem(itemId: itemId, vaultId: vaultId, shareId: shareId, context: context)
        try await gate.wait()
        return result
    }
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        try await resolver.resolveTOTP(itemId: itemId, vaultId: vaultId, shareId: shareId, context: context)
    }
}

private struct FieldSnapshotViewer: OfflineItemViewing {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        let original = try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "fixture")
        let data = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var content = try #require(object["content"] as? [String: Any])
        var typed = try #require(content["content"] as? [String: Any])
        var login = try #require(typed["Login"] as? [String: Any])
        login["email"] = "field@example.test"
        typed["Login"] = login
        content["content"] = typed
        object["content"] = content
        return try JSONDecoder().decode(CLIItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private struct FixedResolvedItemResolver: SecretItemResolving {
    let item: ResolvedSecret<CLIItem>
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> { item }
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> { throw CancellationError() }
}
