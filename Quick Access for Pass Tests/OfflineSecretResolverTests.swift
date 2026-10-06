import Foundation
import GRDB
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline secret resolver", .timeLimit(.minutes(1)))
struct OfflineSecretResolverTests {
    @Test func liveItemWinsOverAuthorizedSnapshot() async throws {
        let fixture = try await selectedFixture()
        let resolver = OfflineSecretResolver(
            live: ResolverLive(item: try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "live")),
            repository: fixture.repository,
            codec: fixture.codec,
            readiness: fixture.service
        )

        let value = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        guard case .login(let login) = value.content.content else { Issue.record("expected login"); return }
        #expect(login.password == "live")
    }

    @Test func unavailableLiveTOTPUsesAuthorizedEncryptedSnapshot() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8")
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service
        )
        #expect(try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share").count == 8)
    }

    @Test func fallbackRequiresReadinessAndCurrentRepositoryAuthorization() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let codec = fixture.codec()
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: codec, readiness: NotReady()
        )
        await #expect {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        } throws: { error in
            guard let error = error as? CLIError, case .notLoggedIn = error else { return false }
            return true
        }
    }

    @Test func cachedFallbackValidatesExpectedUsernameBeforeRelease() async throws {
        let fixture = try await selectedFixture()
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service
        )
        let context = SecretResolutionContext(
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000,
            expectedUsername: "different-user"
        )

        await #expect {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        } throws: { error in
            guard let error = error as? AutoFillSecretResolverError, case .usernameMismatch = error else { return false }
            return true
        }
    }

    @Test func unselectedLiveAttemptReceivesWholeRemainingDeadline() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: fixture.codec(), readiness: AutoReady(), now: { 1_000_000_000 }
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: nil)
        _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        #expect(await live.timeouts() == [4])
    }

    @Test func expiredDeadlineDoesNotStartLiveOrFallback() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: fixture.codec(), readiness: AutoReady(), now: { 5_000_000_000 }
        )
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: .init(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: nil))
        }
        #expect(await live.timeouts().isEmpty)
    }

    @Test func notReadySelectedSnapshotKeepsWholeLiveBudgetWithoutDecoding() async throws {
        let fixture = try await selectedFixture()
        let live = TimedLiveRecorder()
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: codec, readiness: NotReady(), now: { 1_000_000_000 }
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: nil)

        _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)

        #expect(await live.timeouts() == [4])
        #expect(await codec.decodeCount() == 0)
    }

    @Test func insufficientSelectedReserveStartsNeitherLiveNorSnapshotDecode() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let live = TimedLiveRecorder()
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: codec, readiness: fixture.service, now: { 4_000_000_000 }
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: "user")

        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        #expect(await live.timeouts().isEmpty)
        #expect(await codec.decodeCount() == 0)
    }

    @Test func deadlineExpiringBetweenIdentityAndTOTPNeverStartsFallback() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let live = AdvancingTimedLive(clock: clock)
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let adapter = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: codec, readiness: fixture.service,
            now: { clock.withLock { $0 } }
        ))
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: descriptor.username)

        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await adapter.resolve(descriptor: descriptor, kind: .oneTimeCode, context: context)
        }
        #expect(await live.timeouts() == [2])
        #expect(await codec.decodeCount() == 0)
    }

    @Test func cachedTOTPRetryValidatesReplacementUsernameIndependently() async throws {
        let fixture = try await selectedFixture(
            totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=999999999"
        )
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let stale = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let request = OfflineRequestToken(
            id: UUID(), key: key, shareID: "share", metadataModifyTime: Date(timeIntervalSince1970: 2),
            itemType: .login, selectionGeneration: UUID()
        )
        let replacement = try await fixture.codec.prepareSnapshot(
            from: offlineTestCLIItem(
                id: "item", vaultID: "vault", shareID: "share", password: "replacement",
                username: "replacement@example.test", totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=999999999"
            ),
            for: request
        )
        let codec = DelayedReplacementRaceCodec(
            codec: fixture.codec, staleRevision: stale.identity.revision,
            database: fixture.database, replacement: replacement
        )
        let adapter = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: codec, readiness: fixture.service
        ))
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "user", serviceIdentifier: "example.test", hasTOTP: true
        )
        let context = SecretResolutionContext(
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000,
            expectedUsername: "user"
        )

        await #expect(throws: AutoFillSecretResolverError.usernameMismatch) {
            _ = try await adapter.resolve(descriptor: descriptor, kind: .oneTimeCode, context: context)
        }
    }

    @Test func cachedEmptyUsernameEmailMismatchRejectsPasswordAndTOTP() async throws {
        let totp = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=999999999"
        let fixture = try await selectedFixture(totp: totp, username: "", email: "different@example.test")
        let adapter = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service
        ))
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true
        )
        let context = SecretResolutionContext(
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000,
            expectedUsername: descriptor.username
        )

        for kind in [AutoFillValueKind.password, .oneTimeCode] {
            await #expect(throws: AutoFillSecretResolverError.usernameMismatch) {
                _ = try await adapter.resolve(descriptor: descriptor, kind: kind, context: context)
            }
        }
    }

    @Test func cancellationAfterActualSnapshotDecryptionRejectsDecodedValue() async throws {
        let fixture = try await selectedFixture()
        let gate = OfflineTestGate()
        let codec = PostDecodeGateCodec(codec: fixture.codec, gate: gate)
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: codec, readiness: fixture.service
        )
        let task = Task {
            try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        do {
            try await gate.waitUntilEntered()
            task.cancel()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test func authenticatedMarkerPayloadDecodeFailureIsClassifiedWithoutLeakage() async throws {
        let fixture = try await selectedFixture()
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let marker = "<<TASK7_DECODE_PAYLOAD_MARKER>>"
        let payload = try cipher.seal(Data("not-json-\(marker)".utf8), for: snapshot.identity)
        try await fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE offlineSnapshots SET encryptedPayload = ? WHERE vaultId = ? AND itemId = ?",
                arguments: [payload, "vault", "item"]
            )
        }
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service
        )
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
    }

    @Test func malformedLiveFailureDoesNotUseSnapshot() async throws {
        let fixture = try await selectedFixture()
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .parseError("malformed")), repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service
        )
        await #expect(throws: CLIError.self) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
    }

    @Test func missingOrWrongKeyNeverDeletesAnAuthorizedSnapshot() async throws {
        let fixture = try await selectedFixture()
        let missingKeyResolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: OfflineSnapshotCodec(
                keyMaterialProvider: OfflineFixtureKeys(initialMaterial: nil),
                hasPersistedSnapshots: { true }
            ), readiness: fixture.service
        )
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await missingKeyResolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        #expect(try await fixture.repository.hasAuthorizedSnapshot(for: key))

        let wrongKeyResolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: OfflineSnapshotCodec(
                keyMaterialProvider: OfflineFixtureKeys(initialMaterial: Data(repeating: 8, count: 32)),
                hasPersistedSnapshots: { true }
            ), readiness: fixture.service
        )
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await wrongKeyResolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(try await fixture.repository.hasAuthorizedSnapshot(for: key))
    }

    @Test func corruptDecodeCannotDiscardAValidReplacement() async throws {
        let fixture = try await selectedFixture()
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let stale = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let request = OfflineRequestToken(
            id: UUID(), key: key, shareID: "share", metadataModifyTime: Date(timeIntervalSince1970: 2),
            itemType: .login, selectionGeneration: UUID()
        )
        let replacement = try await fixture.codec.prepareSnapshot(
            from: offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "replacement"),
            for: request
        )
        let racingCodec = ReplacementRaceCodec(
            codec: fixture.codec, staleRevision: stale.identity.revision,
            database: fixture.database, replacement: replacement
        )
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: racingCodec, readiness: fixture.service
        )

        let item = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        guard case .login(let login) = item.content.content else { Issue.record("expected login"); return }
        #expect(login.password == "replacement")
        #expect(try await fixture.repository.authorizedSnapshot(for: key)?.identity.revision == replacement.identity.revision)
    }

    @Test("native overflow during timeout refuses selected snapshot decode and release", arguments: [false, true])
    func nativeTimeoutOverflowNeverDecodesOrReleasesSelectedSnapshot(delayedNotification: Bool) async throws {
        let selected = try await selectedFixture()
        let native = NativeTimeoutOverflowFixture(delayedNotification: delayedNotification)
        defer { native.removeMarkers() }
        let codec = DecodeCountingCodec(codec: selected.codec)
        let cli = PassCLIService(cliPath: "/bin/sh", runner: NativeTimeoutOverflowRunner(fixture: native))
        let resolver = OfflineSecretResolver(live: cli, repository: selected.repository, codec: codec, readiness: selected.service)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000, expectedUsername: nil)
        let released = OSAllocatedUnfairLock(initialState: false)
        await #expect {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
            released.withLock { $0 = true }
        } throws: { error in
            guard let typed = error as? CLIError, case .outputLimitExceeded = typed else { return false }
            return true
        }
        #expect(await codec.decodeCount() == 0)
        #expect(released.withLock { $0 } == false)
        #expect(try await selected.repository.hasPersistedSnapshots())
        native.expectTimeoutTrapAndSingleCompletion()
    }

    private func selectedFixture(
        totp: String = "",
        username: String = "person@example.test",
        email: String = ""
    ) async throws -> SelectedResolverFixture {
        let repositoryFixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(repositoryFixture.items.first)
        let viewer = ResolverViewer(totp: totp, username: username, email: email)
        let codec = repositoryFixture.codec()
        let service = OfflineModeService(repository: repositoryFixture.repository, codec: codec, cliService: viewer)
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        #expect(try await repositoryFixture.repository.offlineVaultIds().isEmpty)
        #expect(try await repositoryFixture.repository.offlineItemSelection(itemId: "item")?.isManuallySelected == true)
        return SelectedResolverFixture(
            database: repositoryFixture.database, repository: repositoryFixture.repository,
            codec: codec, service: service
        )
    }
}

private struct SelectedResolverFixture {
    let database: DatabaseManager
    let repository: OfflineSnapshotRepository
    let codec: OfflineSnapshotCodec
    let service: OfflineModeService
}

private struct ResolverLive: OfflineSecretResolvingLive {
    let item: CLIItem?
    let error: CLIError?
    init(item: CLIItem? = nil, error: CLIError? = nil) { self.item = item; self.error = error }
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { if let error { throw error }; return item! }
    func getTotp(itemId: String, shareId: String) async throws -> String { if let error { throw error }; return "live" }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { try await viewItem(itemId: itemId, shareId: shareId) }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { try await getTotp(itemId: itemId, shareId: shareId) }
}

private struct ResolverViewer: OfflineItemViewing {
    let totp: String
    let username: String
    let email: String
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        let object: [String: Any] = [
            "id": "item", "share_id": "share", "vault_id": "vault",
            "content": [
                "title": "", "note": "", "item_uuid": "content-item",
                "content": ["Login": ["username": username, "email": email, "password": "cached", "totp_uri": totp]]
            ],
            "state": "Active", "flags": [], "create_time": "", "modify_time": ""
        ]
        return try JSONDecoder().decode(
            CLIItem.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

private struct AutoReady: OfflineInitializationProviding { func isReady() async -> Bool { true } }

private actor TimedLiveRecorder: OfflineSecretResolvingLive {
    private var recorded: [TimeInterval] = []
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "live") }
    func getTotp(itemId: String, shareId: String) async throws -> String { "000000" }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { recorded.append(timeout); return try await viewItem(itemId: itemId, shareId: shareId) }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { recorded.append(timeout); return "000000" }
    func timeouts() -> [TimeInterval] { recorded }
}

private struct NotReady: OfflineInitializationProviding {
    func isReady() async -> Bool { false }
}

private actor AdvancingTimedLive: OfflineSecretResolvingLive {
    private let clock: OSAllocatedUnfairLock<UInt64>
    private var recorded: [TimeInterval] = []

    init(clock: OSAllocatedUnfairLock<UInt64>) { self.clock = clock }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "live")
    }

    func getTotp(itemId: String, shareId: String) async throws -> String { "000000" }

    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem {
        recorded.append(timeout)
        clock.withLock { $0 = 5_000_000_000 }
        return try await viewItem(itemId: itemId, shareId: shareId)
    }

    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String {
        recorded.append(timeout)
        return "000000"
    }

    func timeouts() -> [TimeInterval] { recorded }
}

private actor PostDecodeGateCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private let gate: OfflineTestGate

    init(codec: OfflineSnapshotCodec, gate: OfflineTestGate) {
        self.codec = codec
        self.gate = gate
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        let item = try await codec.decodeSnapshot(snapshot)
        try await gate.wait()
        return item
    }
}

private actor DecodeCountingCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private var decodes = 0

    init(codec: OfflineSnapshotCodec) { self.codec = codec }

    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        decodes += 1
        return try await codec.decodeSnapshot(snapshot)
    }

    func decodeCount() -> Int { decodes }
}

private actor DelayedReplacementRaceCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private let staleRevision: UUID
    private let database: DatabaseManager
    private let replacement: EncryptedOfflineSnapshot
    private var decodeAttempts = 0
    private var replaced = false

    init(
        codec: OfflineSnapshotCodec,
        staleRevision: UUID,
        database: DatabaseManager,
        replacement: EncryptedOfflineSnapshot
    ) {
        self.codec = codec
        self.staleRevision = staleRevision
        self.database = database
        self.replacement = replacement
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        decodeAttempts += 1
        if decodeAttempts > 1, snapshot.identity.revision == staleRevision, !replaced {
            replaced = true
            try await database.writer.write { db in
                try db.execute(
                    sql: """
                    UPDATE offlineSnapshots
                    SET schemaVersion = ?, snapshotRevision = ?, keyFingerprint = ?, encryptedPayload = ?
                    WHERE vaultId = ? AND itemId = ?
                    """,
                    arguments: [
                        replacement.identity.key.schemaVersion,
                        replacement.identity.revision.uuidString,
                        replacement.identity.keyFingerprint,
                        replacement.payload,
                        replacement.identity.key.vaultId,
                        replacement.identity.key.itemId
                    ]
                )
            }
            throw OfflineSnapshotCodec.Error.corruptSnapshot
        }
        return try await codec.decodeSnapshot(snapshot)
    }
}

private actor ReplacementRaceCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private let staleRevision: UUID
    private let database: DatabaseManager
    private let replacement: EncryptedOfflineSnapshot
    private var replaced = false

    init(
        codec: OfflineSnapshotCodec,
        staleRevision: UUID,
        database: DatabaseManager,
        replacement: EncryptedOfflineSnapshot
    ) {
        self.codec = codec
        self.staleRevision = staleRevision
        self.database = database
        self.replacement = replacement
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        if snapshot.identity.revision == staleRevision, !replaced {
            replaced = true
            try await database.writer.write { db in
                try db.execute(
                    sql: """
                    UPDATE offlineSnapshots
                    SET schemaVersion = ?, snapshotRevision = ?, keyFingerprint = ?, encryptedPayload = ?
                    WHERE vaultId = ? AND itemId = ?
                    """,
                    arguments: [
                        replacement.identity.key.schemaVersion,
                        replacement.identity.revision.uuidString,
                        replacement.identity.keyFingerprint,
                        replacement.payload,
                        replacement.identity.key.vaultId,
                        replacement.identity.key.itemId
                    ]
                )
            }
            throw OfflineSnapshotCodec.Error.corruptSnapshot
        }
        return try await codec.decodeSnapshot(snapshot)
    }
}
