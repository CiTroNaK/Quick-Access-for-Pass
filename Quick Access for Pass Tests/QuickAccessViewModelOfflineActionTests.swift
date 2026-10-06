import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Quick Access offline actions")
struct QuickAccessViewModelOfflineActionTests {
    @Test @MainActor func staleOfflineRemovalUsesUnifiedRepository() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await service.makeAvailableOffline(item: item, shareId: "share")
        try fixture.database.updateOfflineCacheStatus(itemId: item.id, status: .failed, refreshedAt: .distantPast)
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
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {}, offlineModeCoordinator: coordinator
        )

        #expect(coordinator.availability(for: item) == .stale(lastRefreshedAt: .distantPast))
        viewModel.handleOfflineAvailability(for: item)
        await viewModel.inFlightOfflineOperation?.value
        #expect(try await fixture.repository.authorizedSnapshot(for: OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: 1)) == nil)
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
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {}, offlineModeCoordinator: coordinator
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
        let clipboard = ClipboardManager(autoClearSeconds: 0)
        var presented = false
        let item = offlineTestMetadata(id: "item", vaultID: "vault")
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: ActionGateResolver(gate: gate),
            secretReleaseGuard: guardState,
            presentLargeType: { _ in presented = true }
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
        let clipboard = ClipboardManager(autoClearSeconds: 0)
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
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {}, secretResolver: SensitiveFailureActionResolver()
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
        let clipboard = ClipboardManager(autoClearSeconds: 0)
        var displayedValue: String?
        let live = UnavailableLiveRecorder()
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: fixture.codec(), readiness: service
        )
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: fixture.database), cliService: PassCLIService(),
            clipboardManager: clipboard, onDismiss: {}, secretResolver: resolver,
            presentLargeType: { displayedValue = $0.value }
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
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {},
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
            let clipboard = ClipboardManager(autoClearSeconds: 0)
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
        let clipboard = ClipboardManager(autoClearSeconds: 0)
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
            clipboardManager: ClipboardManager(autoClearSeconds: 0), onDismiss: {}, secretResolver: resolver
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

    @Test @MainActor func copyPasswordUsesInjectedSecretResolver() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try database.upsertVaults([PassVault(id: "vault", name: "Vault", shareId: "share")])
        let clipboard = ClipboardManager(autoClearSeconds: 0)
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

private actor ActionGateResolver: SecretItemResolving {
    private let gate: OfflineTestGate

    init(gate: OfflineTestGate) { self.gate = gate }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        try? await gate.wait()
        return try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "not-released")
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        try? await gate.wait()
        return "000000"
    }
}

private struct DecoderMarkerLive: OfflineSecretResolvingLive {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.notLoggedIn }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.notLoggedIn }
}

private struct UnavailableActionResolver: SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        throw OfflineSecretResolver.Error.unavailable
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        throw OfflineSecretResolver.Error.unavailable
    }
}

private struct SensitiveFailureActionResolver: SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        throw CLIError.commandFailed("<<TASK7_SECRET_MARKER>>")
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        throw CLIError.commandFailed("<<TASK7_SECRET_MARKER>>")
    }
}

private actor OldActionResolver: SecretItemResolving {
    private let gate: OfflineTestGate
    private var itemCalls = 0

    init(gate: OfflineTestGate) { self.gate = gate }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        itemCalls += 1
        if itemCalls == 1 {
            try? await gate.wait()
            return try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "stale")
        }
        throw CLIError.commandFailed("new-action-failure")
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        "000000"
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
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "offline-password")
    }
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String { "000000" }
}
