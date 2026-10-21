import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("SyncCoordinator metadata and AutoFill identities")
@MainActor
struct SyncCoordinatorTests {
    @Test("projects non-secret descriptors before database work and reconciles after commit")
    func reconcilesAfterCommittedMetadataSync() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let recorder = RecordingIdentitySynchronizer(database: database)
        let harness = makeHarness(database: database, synchronizer: recorder)

        harness.coordinator.refreshNow()
        await waitUntil { await recorder.callCount() == 1 }

        let descriptors = try database.allAutoFillDescriptors()
        #expect(descriptors.map(\.serviceIdentifier) == ["accounts.example.org", "login.example.com"])
        #expect(descriptors.allSatisfy { $0.hasTOTP })
        #expect(await recorder.observedCommittedDescriptors())
    }

    @Test("delivers progress while loading and clears loading after sync")
    func deliversProgressAndClearsLoadingAfterSync() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        let synchronizer = BlockingIdentitySynchronizer()
        let completion = SyncIssueObserver()
        let harness = makeHarness(
            database: database,
            synchronizer: synchronizer,
            onSyncIssueChanged: { _ in completion.record() }
        )

        harness.coordinator.refreshNow()
        await synchronizer.waitUntilReconcileStarted()

        #expect(harness.viewModel.isLoading)
        #expect(harness.viewModel.syncProgress == .itemsDecoded(
            vaultName: "Personal",
            completedItems: 1,
            totalItems: 1,
            skippedItems: 0
        ))

        await synchronizer.resume()
        await completion.waitForRecord()
        #expect(harness.viewModel.isLoading == false)
    }

    @Test("failed combined item and descriptor transaction never reconciles system identities")
    func failedTransactionDoesNotReconcile() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
        try await database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failAutoFillDescriptorWrite
                BEFORE INSERT ON autoFillDescriptors
                BEGIN
                    SELECT RAISE(FAIL, 'injected descriptor failure');
                END
                """)
        }
        let recorder = RecordingIdentitySynchronizer(database: database)
        let harness = makeHarness(database: database, synchronizer: recorder)

        harness.coordinator.refreshNow()
        await waitUntil { harness.viewModel.syncError != nil }

        #expect(try database.allVaults().isEmpty)
        #expect(try database.allActiveItems().isEmpty)
        #expect(try database.allAutoFillDescriptors().isEmpty)
        #expect(await recorder.callCount() == 0)
    }

    private func makeHarness(
        database: DatabaseManager,
        synchronizer: any AutoFillIdentitySynchronizing,
        onSyncIssueChanged: @escaping @MainActor @Sendable (QuickAccessSyncIssuePresentation?) -> Void = { _ in }
    ) -> (coordinator: SyncCoordinator, viewModel: QuickAccessViewModel) {
        let cliService = PassCLIService(cliPath: "/usr/bin/pass", runner: SuccessfulSyncCLIRunner())
        let viewModel = QuickAccessViewModel(
            searchService: SearchService(databaseManager: database),
            cliService: cliService,
            clipboardManager: ClipboardManager(autoClearSeconds: 0),
            onDismiss: {},
            writeStringToPasteboard: { _ in },
            openURL: { _ in true }
        )
        let coordinator = SyncCoordinator(
            cliService: cliService,
            databaseManager: database,
            viewModel: viewModel,
            identitySynchronizer: synchronizer,
            onSyncIssueChanged: onSyncIssueChanged
        )
        return (coordinator, viewModel)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for sync")
    }
}

private actor RecordingIdentitySynchronizer: AutoFillIdentitySynchronizing {
    private let database: DatabaseManager
    private var calls = 0
    private var sawCommittedDescriptors = false

    init(database: DatabaseManager) {
        self.database = database
    }

    func reconcile(descriptors: [AutoFillCredentialDescriptor]) async throws {
        calls += 1
        sawCommittedDescriptors = (try database.allAutoFillDescriptors()) == descriptors
    }

    func callCount() -> Int { calls }
    func observedCommittedDescriptors() -> Bool { sawCommittedDescriptors }
}

@MainActor
private final class SyncIssueObserver {
    private var hasRecorded = false
    private var continuation: CheckedContinuation<Void, Never>?

    func record() {
        hasRecorded = true
        continuation?.resume()
        continuation = nil
    }

    func waitForRecord() async {
        guard !hasRecorded else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private actor BlockingIdentitySynchronizer: AutoFillIdentitySynchronizing {
    private var hasStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func reconcile(descriptors: [AutoFillCredentialDescriptor]) async throws {
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilReconcileStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor SuccessfulSyncCLIRunner: CLIRunning {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data {
        if arguments == ["vault", "list", "--output", "json"] {
            return Data("""
                {"vaults":[{"name":"Personal","vault_id":"vault-id","share_id":"share-id"}]}
                """.utf8)
        }
        if arguments == ["--version"] {
            return Data("2.2.1".utf8)
        }
        if arguments.first == "item", arguments.dropFirst().first == "list" {
            return Data("""
                {"items":[{
                  "id":"item-id",
                  "share_id":"share-id",
                  "vault_id":"vault-id",
                  "state":"Active",
                  "flags":[],
                  "create_time":"2026-09-24T12:00:00Z",
                  "modify_time":"2026-09-24T12:00:00Z",
                  "content":{
                    "title":"Example",
                    "note":"",
                    "item_uuid":"item-id",
                    "content":{"Login":{
                      "email":"fallback@example.com",
                      "username":"person@example.com",
                      "password":"transient-password-secret",
                      "urls":[
                        "https://Login.Example.com/path",
                        "https://accounts.example.org/sign-in",
                        "https://login.example.com/duplicate"
                      ],
                      "totp_uri":"otpauth://totp/example?secret=TRANSIENTSEED",
                      "passkeys":[]
                    }},
                    "extra_fields":[]
                  }
                }]}
                """.utf8)
        }
        throw CLIError.commandFailed("unexpected test command")
    }
}
