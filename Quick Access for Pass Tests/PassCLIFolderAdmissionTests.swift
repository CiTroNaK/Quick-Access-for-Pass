import Foundation
import Synchronization
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

    @Test("routine preparation reuses the probe while the executable file is unchanged")
    func reusesProbeForUnchangedExecutable() async throws {
        let runner = FolderVersionRunner(versions: ["2.5.1", "2.4.2"])
        let fingerprint = Mutex(Self.fingerprint(size: 1))
        let service = PassCLIService(cliPath: "/fake/a", runner: runner,
                                     executableFingerprint: { _ in fingerprint.withLock { $0 } })
        let first = try #require(await service.prepareFolderSync())
        #expect(await service.prepareFolderSync() == first)
        #expect(service.folderFeatureGate.isCurrent(first))
        #expect(service.folderFeatureGate.availability == .supported)
        #expect(await runner.arguments().count == 1)
        fingerprint.withLock { $0 = Self.fingerprint(size: 2) }
        #expect(await service.prepareFolderSync() == nil)
        #expect(!service.folderFeatureGate.isCurrent(first))
        #expect(service.folderFeatureGate.availability == .requiresUpgrade)
        #expect(await runner.arguments().count == 2)
    }

    @Test("a failed version probe is unavailable but not reused as a negative answer")
    func failedProbeIsInconclusive() async throws {
        let runner = FolderVersionRunner(versions: ["", "2.5.1"], failingCalls: [0])
        let fingerprint = Self.fingerprint(size: 1)
        let service = PassCLIService(cliPath: "/fake/a", runner: runner, executableFingerprint: { _ in fingerprint })
        #expect(await service.prepareFolderSync() == nil)
        #expect(service.folderFeatureGate.availability == .unavailable)
        let stamp = try #require(await service.prepareFolderSync())
        #expect(service.folderFeatureGate.isCurrent(stamp))
        #expect(await runner.arguments().count == 2)
    }

    private static func fingerprint(size: Int) -> PassCLIExecutableFingerprint {
        PassCLIExecutableFingerprint(resolvedPath: "/fake/a", fileSystemNumber: 1, fileNumber: 1, size: size,
                                     modificationDate: Date(timeIntervalSince1970: 0))
    }

    @Test("an uninspectable executable reprobes a replacement at the same path")
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

    @Test("unknown versions do not admit folder work", arguments: ["", "not a version", "2.4.2"])
    func rejectsUnknownVersion(raw: String) async {
        let service = PassCLIService(cliPath: "/fake/a", runner: FolderVersionRunner(versions: [raw]))
        #expect(await service.prepareFolderSync() == nil)
    }
}

private actor FolderVersionRunner: CLIRunning {
    let versions: [String]
    let firstProbeBarrier: IncrementalSyncGate?
    let failingCalls: Set<Int>
    private var calls: [[String]] = []

    init(versions: [String], firstProbeBarrier: IncrementalSyncGate? = nil, failingCalls: Set<Int> = []) {
        self.versions = versions
        self.firstProbeBarrier = firstProbeBarrier
        self.failingCalls = failingCalls
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        let index = calls.count
        calls.append(arguments)
        if index == 0 { await firstProbeBarrier?.wait() }
        if failingCalls.contains(index) { throw CLIError.timeout }
        if arguments != ["--version"] { return Data("{\"vaults\":[]}".utf8) }
        return Data(versions[min(index, versions.count - 1)].utf8)
    }

    func arguments() -> [[String]] { calls }
}
