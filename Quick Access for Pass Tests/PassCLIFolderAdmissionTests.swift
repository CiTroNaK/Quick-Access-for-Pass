import Foundation
import Observation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Pass CLI folder admission", .timeLimit(.minutes(1)))
struct PassCLIFolderAdmissionTests {
    @Test("a cold probe establishes support before any secret command")
    func coldProbeIsMetadataOnly() async throws {
        let runner = FolderVersionRunner(versions: ["2.5.0"])
        let service = PassCLIService(cliPath: "/fake/a", runner: runner)
        let stamp = try #require(await service.prepareFolderSync())
        #expect(service.folderFeatureGate.isCurrent(stamp))
        #expect(await runner.arguments() == [["--version"]])
    }

    @Test("selection replacement invalidates supported evidence synchronously")
    func selectionRevokesSupport() async throws {
        let service = PassCLIService(cliPath: "/fake/a", runner: FolderVersionRunner(versions: ["2.5.1"]))
        let stamp = try #require(await service.prepareFolderSync())
        service.updateCLIPath("/fake/b")
        #expect(!service.folderFeatureGate.isCurrent(stamp))
        #expect(service.folderFeatureGate.availability == .checking)
    }

    @Test("explicit preparation reprobes a replacement at the same path")
    func reprobesSamePath() async throws {
        let runner = FolderVersionRunner(versions: ["2.5.1", "2.4.2"])
        let service = PassCLIService(cliPath: "/fake/a", runner: runner)
        let old = try #require(await service.prepareFolderSync())
        #expect(await service.prepareFolderSync() == nil)
        #expect(!service.folderFeatureGate.isCurrent(old))
        #expect(service.folderFeatureGate.availability == .requiresUpgrade)
        #expect(await runner.arguments().count == 2)
    }

    @Test("late same-selection supported response cannot win over newer unsupported response")
    func sameSelectionProbeOrdering() async {
        let barrier = IncrementalSyncGate()
        let runner = FolderVersionRunner(versions: ["2.5.1", "2.4.2"], firstProbeBarrier: barrier)
        let service = PassCLIService(cliPath: "/fake/a", runner: runner)
        let old = Task { await service.prepareFolderSync() }
        await barrier.waitUntilEntered()
        #expect(await service.prepareFolderSync() == nil)
        await barrier.open()
        #expect(await old.value == nil)
        #expect(service.folderFeatureGate.availability == .requiresUpgrade)
    }

    @Test("a superseded invocation cannot borrow a newer supported probe stamp")
    func supersededInvocationCannotBorrowStamp() async throws {
        let barrier = IncrementalSyncGate()
        let runner = FolderVersionRunner(versions: ["2.5.1", "2.5.1"], firstProbeBarrier: barrier)
        let service = PassCLIService(cliPath: "/fake/a", runner: runner)
        let old = Task { await service.prepareFolderSync() }
        await barrier.waitUntilEntered()
        let current = try #require(await service.prepareFolderSync())
        await barrier.open()
        #expect(await old.value == nil)
        #expect(service.folderFeatureGate.isCurrent(current))
    }

    @MainActor
    @Test("cold coordinator sync resolves capability before capture admission")
    func coordinatorProbesBeforeCapture() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let base = OfflineSnapshotRepository(database: database)
        let repository = IncrementalSyncRepository(base: base)
        let barrier = IncrementalSyncGate()
        await repository.setCaptureGate(barrier)
        let cli = PassCLIService(cliPath: "/fake/a", runner: FolderVersionRunner(versions: ["2.5.1"]))
        let codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(), hasPersistedSnapshots: {
            try await base.hasPersistedSnapshots()
        })
        let service = OfflineModeService(repository: repository, codec: codec, cliService: cli)
        try await initializeOfflineFixtureService(service)
        let viewModel = QuickAccessViewModel(searchService: SearchService(databaseManager: database),
                                            cliService: cli, clipboardManager: ClipboardManager(), onDismiss: {})
        let coordinator = SyncCoordinator(cliService: cli, databaseManager: database,
                                          viewModel: viewModel, offlineModeService: service)
        coordinator.refreshNow()
        await barrier.waitUntilEntered()
        let wasSupportedAtAdmission = cli.folderFeatureGate.supportedStamp() != nil
        await barrier.open()
        await coordinator.currentSyncCompletion?.value
        #expect(wasSupportedAtAdmission)
    }

    @MainActor
    @Test("gate confirmations and invalidations publish observable presentation")
    func availabilityIsObservable() async {
        let gate = FolderFeatureGate(selection: .custom(path: "/fake/a"))
        let store = PassCLIStatusStore()
        store.observeFolderAvailability(from: gate)
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = store.folderFeatureAvailability
            } onChange: {
                continuation.resume()
            }
            gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: gate.beginProbe())
        }
        #expect(store.folderFeatureAvailability == .supported)
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = store.folderFeatureAvailability
            } onChange: {
                continuation.resume()
            }
            gate.updateSelection(.custom(path: "/fake/b"))
        }
        #expect(store.folderFeatureAvailability == .checking)
    }

    @Test("unknown versions do not admit folder work", arguments: ["", "not a version", "2.4.2"])
    func rejectsUnknownVersion(raw: String) async {
        let service = PassCLIService(cliPath: "/fake/a", runner: FolderVersionRunner(versions: [raw]))
        #expect(await service.prepareFolderSync() == nil)
    }
}

private actor FolderVersionRunner: CLIRunning {
    let versions: [String]
    let firstProbeBarrier: IncrementalSyncGate?
    private var calls: [[String]] = []

    init(versions: [String], firstProbeBarrier: IncrementalSyncGate? = nil) {
        self.versions = versions
        self.firstProbeBarrier = firstProbeBarrier
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        let index = calls.count
        calls.append(arguments)
        if index == 0 { await firstProbeBarrier?.wait() }
        if arguments != ["--version"] { return Data("{\"vaults\":[]}".utf8) }
        return Data(versions[min(index, versions.count - 1)].utf8)
    }

    func arguments() -> [[String]] { calls }
}
