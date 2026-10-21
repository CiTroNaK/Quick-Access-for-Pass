import AppKit
import Foundation
import GRDB
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline secret resolver", .timeLimit(.minutes(1)))
struct OfflineSecretResolverTests {
    @Test func eligibilityReadFailureKeepsItemLiveAccess() async throws {
        let fixture = try await selectedFixture()
        let repository = OfflineSnapshotRepository(database: fixture.database, beforeEligibilityRead: {
            throw OfflinePersistenceError.persistenceFailed
        })
        let live = TimedLiveRecorder()
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(live: live, repository: repository, codec: codec, readiness: fixture.service)
        let result = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        let password = try result.map { item -> String in
            guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
            return login.password
        }
        #expect(password.value == "live")
        #expect(await live.callCount() == 1)
        #expect(await codec.decodeCount() == 0)
    }

    @Test func eligibilityReadFailureKeepsTOTPAndAutoFillLiveAccess() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let repository = OfflineSnapshotRepository(database: fixture.database, beforeEligibilityRead: {
            throw OfflinePersistenceError.persistenceFailed
        })
        let live = TimedLiveRecorder()
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(live: live, repository: repository, codec: codec, readiness: fixture.service)
        let totp = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share")
        #expect(totp.value == "000000")
        #expect(await live.callCount() == 1)
        #expect(await codec.decodeCount() == 0)

        let autoFillLive = TimedLiveRecorder()
        let autoFillCodec = DecodeCountingCodec(codec: fixture.codec)
        let adapter = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: autoFillLive, repository: repository, codec: autoFillCodec, readiness: fixture.service
        ))
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true
        )
        let result = try await adapter.resolve(
            descriptor: descriptor, kind: .password, context: .ordinary
        )
        #expect(result.value == "live")
        #expect(await autoFillLive.callCount() == 1)
        #expect(await autoFillCodec.decodeCount() == 0)
    }

    @Test func eligibilityLookupCancellationStartsNeitherLiveNorDecode() async throws {
        let fixture = try await selectedFixture()
        let repository = OfflineSnapshotRepository(database: fixture.database, beforeEligibilityRead: {
            throw CancellationError()
        })
        let live = TimedLiveRecorder()
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(live: live, repository: repository, codec: codec, readiness: fixture.service)
        await #expect(throws: CancellationError.self) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(await live.callCount() == 0)
        #expect(await codec.decodeCount() == 0)
    }

    @Test func deadlineExpiryDuringEligibilityLookupStartsNeitherLiveNorDecode() async throws {
        let fixture = try await selectedFixture()
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let repository = OfflineSnapshotRepository(database: fixture.database, beforeEligibilityRead: {
            clock.withLock { $0 = 5_000_000_000 }
        })
        let live = TimedLiveRecorder(now: { clock.withLock { $0 } })
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(
            live: live, repository: repository, codec: codec, readiness: fixture.service,
            now: { clock.withLock { $0 } }
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: nil)
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        #expect(await live.callCount() == 0)
        #expect(await codec.decodeCount() == 0)
    }

    @Test func liveDeadlinePreservesOriginalBudgetWithoutClockRefresh() throws {
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: nil)
        #expect(try OfflineAutoFillLiveBudget.deadline(context: context, now: 1_000_000_000)?.uptimeNanoseconds == 5_000_000_000)
        let nearOverflow = SecretResolutionContext(deadlineUptimeNanoseconds: UInt64.max, expectedUsername: nil)
        #expect(try OfflineAutoFillLiveBudget.deadline(context: nearOverflow, now: UInt64.max - 1_500_000_000)?.uptimeNanoseconds == UInt64.max)
        #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try OfflineAutoFillLiveBudget.deadline(context: context, now: 5_000_000_000)
        }
    }

    @Test func retainedMappedCapabilityReleasesOnceAndCleansCapture() async throws {
        let fixture = try await selectedFixture()
        let authority = fixture.repository.releaseAuthority
        func releaseOnce() async throws {
            let item = try await OfflineSecretResolver(live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
                codec: fixture.codec, readiness: fixture.service).resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
            let password = try item.map { item -> String in
                guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
                return login.password
            }
            #expect(authority.registrationCount == 1)
            var effects = 0
            try password.release(validating: {}, effect: { value in effects += 1; #expect(value == "cached") })
            #expect(throws: OfflineReleaseError.alreadyConsumed) {
                try password.release(validating: {}, effect: { _ in effects += 1 })
            }
            #expect(effects == 1)
        }
        try await releaseOnce()
        #expect(authority.registrationCount == 0)
    }

    @Test func typeTransitionDuringDecodeDoesNotReauthorizeObsoletePayload() async throws {
        let fixture = try await selectedFixture()
        let gate = OfflineTestGate()
        let live = ResolverLive(error: .notLoggedIn)
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository,
            codec: PostDecodeGateCodec(codec: fixture.codec, gate: gate), readiness: fixture.service)
        let task = Task { try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share") }
        do {
            try await gate.waitUntilEntered()
            #expect(fixture.repository.releaseAuthority.registrationCount == 1)
            try fixture.database.upsertItems([PassItem(id: "item", vaultId: "vault", title: "Type changed", itemType: .note,
                subtitle: "", url: nil, hasTOTP: false, state: "Active", createTime: .distantPast, modifyTime: .distantFuture,
                useCount: 0, lastUsedAt: nil)])
            await gate.open()
            await #expect(throws: OfflineSecretResolver.Error.unavailable) { try await task.value }
            #expect(fixture.repository.releaseAuthority.registrationCount == 0)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
        #expect(live.callCount() == 0)
    }

    @Test func replacementDuringDecodeRetriesWithFreshCaptureAndPayload() async throws {
        let fixture = try await selectedFixture()
        let gate = OfflineTestGate()
        let live = ResolverLive(error: .notLoggedIn)
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository,
            codec: PostDecodeGateCodec(codec: fixture.codec, gate: gate), readiness: fixture.service)
        let task = Task { try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share") }
        do {
            try await gate.waitUntilEntered()
            let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
            let replacement = try await fixture.codec.prepareSnapshot(from: offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "replacement"), for: request)
            #expect(try await fixture.repository.publish(replacement, for: request, refreshedAt: Date()))
            await gate.open()
            let result = try await task.value
            let password = try result.map { item -> String in
                guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
                return login.password
            }
            try password.release(validating: {}, effect: { #expect($0 == "replacement") })
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
        #expect(live.callCount() == 0)
    }

    @Test @MainActor func liveAndUnrelatedCachedValuesSurvivePendingRealRemoval() async throws {
        let gate = OfflineTestGate()
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target", "neighbor"], offlineMutationTesting: OfflineMutationTesting(afterAdmission: { scope in
            if case .itemID("target") = scope { try? await gate.wait() }
        }))
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        for item in fixture.items where item.id == "neighbor" { try await service.makeAvailableOffline(item: item, shareId: "share") }
        let cached = try await OfflineSecretResolver(live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: fixture.codec(), readiness: service).resolveItem(itemId: "neighbor", vaultId: "vault", shareId: "share")
        let live = try await OfflineSecretResolver(live: ResolverLive(item: offlineTestCLIItem(id: "target", vaultID: "vault", shareID: "share", password: "live")),
            repository: fixture.repository, codec: fixture.codec(), readiness: service).resolveItem(itemId: "target", vaultId: "vault", shareId: "share")
        #expect(live.offlineCapability == nil)
        let removal = Task { try await fixture.repository.removeItem("target") }
        try await gate.waitUntilEntered()
        do {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let clipboard = ClipboardManager(autoClearSeconds: 0, pasteboard: pasteboard)
            let password = try live.map { item -> String in
                guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
                return login.password
            }
            try password.release(validating: {}, effect: { clipboard.writeConcealedValue($0) })
            clipboard.completeCopy(label: "Fixture copied")
            #expect(pasteboard.string(forType: .string) == "live")
            let display = try cached.map { item -> LargeTypeDisplay in
                guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
                return try LargeTypeDisplay(validating: login.password)
            }
            let controller = LargeTypeWindowController(presentationMode: .headless)
            defer { controller.close() }
            let prepared = controller.prepare(display: display.value, relativeTo: nil)
            defer { controller.discard(prepared) }
            try controller.activatePreparedWindow(prepared)
            try display.release(validating: {}, effect: { _ in try controller.present(prepared) })
            controller.completePresentation(prepared)
            #expect(controller.debugHostingController != nil)
            await gate.open()
            try await removal.value
        } catch {
            await gate.open()
            _ = await removal.result
            throw error
        }
    }

    @Test func changedMetadataTypeCannotAuthorizeOldDecodedSnapshot() async throws {
        let fixture = try await selectedFixture()
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let item = PassItem(id: "item", vaultId: "vault", title: "Type changed", itemType: .note,
                            subtitle: "", url: nil, hasTOTP: false, state: "Active",
                            createTime: .distantPast, modifyTime: .distantFuture, useCount: 0, lastUsedAt: nil)
        try fixture.database.upsertItems([item])
        let resolver = OfflineSecretResolver(live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
                                             codec: fixture.codec, readiness: fixture.service)
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
    }

    @Test func authorizedSnapshotWinsWithoutLiveCalls() async throws {
        let fixture = try await selectedFixture()
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service)
        let result = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        #expect(result.offlineCapability != nil)
        try result.release(validating: {}, effect: { item in
            guard case .login(let login) = item.content.content else { Issue.record("expected login"); return }
            #expect(login.password == "cached")
        })
        #expect(await live.callCount() == 0)
    }

    @Test func authorizedSnapshotIgnoresGenericSanitizedLiveFailure() async throws {
        let fixture = try await selectedFixture()
        let live = ResolverLive(error: .secretFetchFailed)
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository, codec: fixture.codec, readiness: fixture.service)
        let result = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        #expect(result.offlineCapability != nil)
        try result.release(validating: {}, effect: { item in
            guard case .login(let login) = item.content.content else { Issue.record("expected login"); return }
            #expect(login.password == "cached")
        })
        #expect(live.callCount() == 0)
    }

    @Test("cached missing and malformed TOTP fields never select live", arguments: ["", "<<MALFORMED_TOTP_MARKER>>"])
    func unusableCachedTOTPFieldIsTerminal(uri: String) async throws {
        let fixture = try await selectedFixture(totp: uri)
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository, codec: fixture.codec, readiness: fixture.service)
        await #expect { _ = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share") } throws: { error in
            uri.isEmpty ? (error as? OfflineSecretResolver.Error) == .unavailable : (error as? TOTPGenerator.Error) == .unsupportedURI
        }
        await #expect {
            _ = try await resolver.resolveAutoFillValue(itemId: "item", vaultId: "vault", shareId: "share", kind: .oneTimeCode,
                context: .init(deadlineUptimeNanoseconds: nil, expectedUsername: "person@example.test"))
        } throws: { error in
            uri.isEmpty ? (error as? AutoFillSecretResolverError) == .descriptorDoesNotSupportValue : (error as? TOTPGenerator.Error) == .unsupportedURI
        }
        #expect(await live.callCount() == 0)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test func cachedTOTPUsesCurrentTimeWithoutLiveCalls() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8")
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service, totpDate: { Date(timeIntervalSince1970: 59) })
        let result = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share")
        #expect(result.offlineCapability != nil)
        try result.release(validating: {}, effect: { #expect($0 == "94287082") })
        #expect(await live.callCount() == 0)
    }

    @Test func cachedAutoFillValuesSkipLiveResolution() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8")
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service, totpDate: { Date(timeIntervalSince1970: 59) })
        for (kind, expected) in [(AutoFillValueKind.password, "cached"), (.oneTimeCode, "94287082")] {
            let result = try await resolver.resolveAutoFillValue(itemId: "item", vaultId: "vault", shareId: "share",
                kind: kind, context: .init(deadlineUptimeNanoseconds: nil, expectedUsername: "person@example.test"))
            #expect(result.offlineCapability != nil)
            try result.release(validating: {}, effect: { #expect($0 == expected) })
        }
        #expect(await live.callCount() == 0)
    }

    @Test("key availability uses live once without removing ciphertext or selection", arguments: [false, true])
    func keyUnavailableUsesLiveWithoutDeletingSnapshot(wrongKey: Bool) async throws {
        let fixture = try await selectedFixture()
        let before = try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item")
        let keys = OfflineFixtureKeys(initialMaterial: wrongKey ? Data(repeating: 8, count: 32) : nil)
        let codec = DecodeCountingCodec(codec: OfflineSnapshotCodec(keyMaterialProvider: keys, hasPersistedSnapshots: { true }))
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository, codec: codec, readiness: fixture.service)
        let result = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        #expect(result.offlineCapability == nil)
        try result.release(validating: {}, effect: { item in
            guard case .login(let login) = item.content.content else { Issue.record("expected login"); return }
            #expect(login.password == "live")
        })
        #expect(await codec.decodeCount() == 2)
        #expect(await live.callCount() == 1)
        #expect(try await OfflinePersistedTestState.capture(database: fixture.database, itemID: "item") == before)
        #expect(try await keys.existingSnapshotKey() == (wrongKey ? Data(repeating: 8, count: 32) : nil))
    }

    @Test func corruptSnapshotUsesLiveAndRetainsSelectionAndKey() async throws {
        let fixture = try await selectedFixture()
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let payload = try cipher.seal(Data("not-json-<<CACHE_MARKER>>".utf8), for: snapshot.identity)
        try await fixture.database.writer.write { db in
            try db.execute(sql: "UPDATE offlineSnapshots SET encryptedPayload = ? WHERE itemId = ?", arguments: [payload, "item"])
        }
        let live = TimedLiveRecorder()
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository, codec: codec, readiness: fixture.service)
        let result = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        #expect(result.offlineCapability == nil)
        try result.release(validating: {}, effect: { item in
            guard case .login(let login) = item.content.content else { Issue.record("expected login"); return }
            #expect(login.password == "live")
        })
        #expect(await codec.decodeCount() == 1)
        #expect(await live.callCount() == 1)
        #expect(try await fixture.repository.authorizedSnapshot(for: key) == nil)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item") != nil)
        // The same device-bound fixture key remains usable; no key cleanup occurred.
        let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .selection))
        let replacement = try await fixture.codec.prepareSnapshot(from: offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "replacement"), for: request)
        #expect(replacement.snapshot.identity.keyFingerprint == snapshot.identity.keyFingerprint)
    }

    @Test("admitted snapshot and proof disappearance stay cache-only", arguments: [false, true])
    func admittedAuthorizationRaceNeverStartsLive(removeBeforeProof: Bool) async throws {
        let fixture = try await selectedFixture()
        let repository = RemovalRaceRepository(base: fixture.repository, removeBeforeProof: removeBeforeProof)
        let live = ResolverLive(item: try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "live"), error: .notLoggedIn)
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(live: live, repository: repository, codec: codec, readiness: fixture.service)
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(live.callCount() == 0)
        #expect(await repository.snapshotReads() == 2)
        #expect(await codec.decodeCount() == 0)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test("non-availability decode errors are terminal", arguments: [OfflineSnapshotCodec.Error.invalidIdentity, .payloadTooLarge, .unsupportedSchemaVersion])
    func terminalDecodeFailureNeverStartsLive(error: OfflineSnapshotCodec.Error) async throws {
        let fixture = try await selectedFixture()
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository,
            codec: FailingResolverCodec(error: error), readiness: fixture.service)
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(await live.callCount() == 0)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test func unknownCacheFailureNeverStartsLiveOrLeaksPayload() async throws {
        let fixture = try await selectedFixture()
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository,
            codec: FailingResolverCodec(error: CLIError.parseError("<<UNKNOWN_CACHE_ERROR_MARKER>>")), readiness: fixture.service)
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(await live.callCount() == 0)
    }

    @Test("selection removal at retry eligibility never becomes live availability", arguments: [false, true])
    func removalAtSecondEligibilityReadRejectsLiveAvailability(corrupt: Bool) async throws {
        let fixture = try await selectedFixture()
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let codec: any OfflineSnapshotCoding
        if corrupt {
            let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
            let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
            let payload = try cipher.seal(Data("not-json-<<RETRY_ELIGIBILITY_MARKER>>".utf8), for: snapshot.identity)
            try await fixture.database.writer.write { db in
                try db.execute(sql: "UPDATE offlineSnapshots SET encryptedPayload = ? WHERE itemId = ?", arguments: [payload, "item"])
            }
            codec = fixture.codec
        } else {
            codec = OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(initialMaterial: nil), hasPersistedSnapshots: { true })
        }
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let repository = OfflineSnapshotRepository(database: fixture.database, beforeEligibilityRead: {
            let shouldRemove = reads.withLock { count in count += 1; return count == 2 }
            if shouldRemove { try await fixture.repository.removeItem("item") }
        })
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: repository, codec: codec, readiness: fixture.service)
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(reads.withLock { $0 } == 2)
        #expect(await live.callCount() == 0)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item") == nil)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test("rollback invalidation at retry eligibility never becomes live availability", arguments: [false, true])
    func rollbackAtSecondEligibilityReadRejectsLiveAvailability(corrupt: Bool) async throws {
        let fixture = try await selectedFixture()
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let repository = OfflineSnapshotRepository(database: fixture.database, beforeEligibilityRead: {
            let shouldInvalidate = reads.withLock { count in count += 1; return count == 2 }
            if shouldInvalidate {
                let mutation = fixture.repository.releaseAuthority.beginMutation(.itemID("item"))
                fixture.repository.releaseAuthority.finishMutation(mutation, outcome: .rolledBack)
            }
        })
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: repository,
            codec: FailingResolverCodec(error: corrupt ? OfflineSnapshotCodec.Error.corruptSnapshot : .keyUnavailable), readiness: fixture.service)
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(await live.callCount() == 0)
        #expect(try await fixture.repository.hasPersistedSnapshots())
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test func keyAvailabilityRetryCannotForgetOriginalReplacementInvalidation() async throws {
        let fixture = try await selectedFixture()
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let repository = OfflineSnapshotRepository(database: fixture.database, beforeEligibilityRead: {
            let shouldReplace = reads.withLock { count in count += 1; return count == 2 }
            if shouldReplace {
                let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
                let replacement = try await fixture.codec.prepareSnapshot(
                    from: offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "replacement"), for: request)
                #expect(try await fixture.repository.publish(replacement, for: request, refreshedAt: Date()))
            }
        })
        let codec = DecodeCountingCodec(codec: OfflineSnapshotCodec(keyMaterialProvider: OfflineFixtureKeys(initialMaterial: nil), hasPersistedSnapshots: { true }))
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: repository, codec: codec, readiness: fixture.service)
        await #expect(throws: OfflineSecretResolver.Error.unavailable) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        }
        #expect(await codec.decodeCount() == 2)
        #expect(await live.callCount() == 0)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test func revocationDuringKeyFailureIsTerminalWithoutLiveRetry() async throws {
        let fixture = try await selectedFixture()
        let gate = OfflineTestGate()
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository,
            codec: PostDecodeGateCodec(codec: fixture.codec, gate: gate, failure: .keyUnavailable), readiness: fixture.service)
        let task = Task { try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share") }
        do {
            try await gate.waitUntilEntered()
            try await fixture.repository.removeItem("item")
            await gate.open()
            await #expect(throws: OfflineSecretResolver.Error.unavailable) { _ = try await task.value }
            #expect(await live.callCount() == 0)
            #expect(fixture.repository.releaseAuthority.registrationCount == 0)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test func failedRefreshKeepsPreferredValueAndSuccessfulRefreshChangesIt() async throws {
        let fixture = try await selectedFixture()
        let item = try #require(try fixture.database.allActiveItems().first)
        let live = TimedLiveRecorder()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository, codec: fixture.codec, readiness: fixture.service)
        for (viewer, expected) in [
            (ResolverLive(error: .notLoggedIn), "cached"),
            (ResolverLive(item: try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "refreshed")), "refreshed")
        ] {
            let refresh = OfflineModeService(repository: fixture.repository, codec: fixture.codec, cliService: viewer)
            try await refresh.initialize()
            await refresh.refreshSelectedSnapshots(vaults: [PassVault(id: "vault", name: "Vault", shareId: "share")], items: [item])
            await refresh.waitUntilIdle()
            let result = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
            #expect(result.offlineCapability != nil)
            try result.release(validating: {}, effect: { item in
                guard case .login(let login) = item.content.content else { Issue.record("expected login"); return }
                #expect(login.password == expected)
            })
        }
        #expect(await live.callCount() == 0)
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
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let live = ResolverLive(error: .notLoggedIn, now: { clock.withLock { $0 } })
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository,
            codec: codec, readiness: fixture.service, now: { clock.withLock { $0 } }
        )
        let context = SecretResolutionContext(
            deadlineUptimeNanoseconds: 5_000_000_000,
            expectedUsername: "different-user"
        )

        var returnedValue = false
        await #expect {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
            returnedValue = true
        } throws: { error in
            guard let error = error as? AutoFillSecretResolverError, case .usernameMismatch = error else { return false }
            return true
        }
        #expect(returnedValue == false)
        #expect(await codec.decodeCount() == 1)
        #expect(live.deadlines().isEmpty)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
        // The same injected clock remains authoritative when it really expires.
        clock.withLock { $0 = 5_000_000_000 }
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        #expect(await codec.decodeCount() == 1)
        #expect(live.deadlines().isEmpty)
    }

    @Test func unselectedLiveAttemptReceivesWholeRemainingDeadline() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let live = TimedLiveRecorder(now: { 1_000_000_000 })
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
        let live = TimedLiveRecorder(now: { 1_000_000_000 })
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: codec, readiness: NotReady(), now: { 1_000_000_000 }
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: nil)

        _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)

        #expect(await live.timeouts() == [4])
        #expect(await codec.decodeCount() == 0)
    }

    @Test func selectedSnapshotNeedsNoLiveFallbackReserve() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let live = TimedLiveRecorder()
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: codec, readiness: fixture.service, now: { 4_000_000_000 }
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: "person@example.test")

        let result = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        #expect(result.offlineCapability != nil)
        #expect(await live.timeouts().isEmpty)
        #expect(await codec.decodeCount() == 1)
    }

    @Test func deadlineExpiringBetweenIdentityAndTOTPNeverStartsFallback() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        try await fixture.repository.removeItem("item")
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
        #expect(await live.timeouts() == [4])
        #expect(await codec.decodeCount() == 0)
    }

    @Test func postPhaseParseFailureDoesNotDecodeFallbackSnapshotForComposedTOTP() async throws {
        let fixture = try await selectedFixture(
            totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=999999999"
        )
        try await fixture.repository.removeItem("item")
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let live = ComposedTOTPParseFailureLive(clock: clock)
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let adapter = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: codec, readiness: fixture.service,
            now: { clock.withLock { $0 } }
        ))
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: descriptor.username)

        await #expect(throws: CLIError.self) {
            _ = try await adapter.resolve(descriptor: descriptor, kind: .oneTimeCode, context: context)
        }
        #expect(await live.deadlines() == [4_000_000_000, 4_000_000_000])
        #expect(await codec.decodeCount() == 0)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test func cachedTOTPWithIssuerMetadataMatchesIssuerlessCode() async throws {
        let issuerBearingURI = "otpauth://totp/Example:alice?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example%20Issuer"
        let fixture = try await selectedFixture(totp: issuerBearingURI)
        let fixedDate = Date(timeIntervalSince1970: 59)
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let live = ResolverLive(error: .notLoggedIn, now: { clock.withLock { $0 } })
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let adapter = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: live, repository: fixture.repository,
            codec: codec, readiness: fixture.service, now: { clock.withLock { $0 } }, totpDate: { fixedDate }
        ))
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true
        )
        let context = SecretResolutionContext(
            deadlineUptimeNanoseconds: 5_000_000_000,
            expectedUsername: "person@example.test"
        )

        let cached = try await adapter.resolve(descriptor: descriptor, kind: .oneTimeCode, context: context)
        let issuerlessURI = "otpauth://totp/Example:alice?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let expected = try TOTPGenerator.code(from: issuerlessURI, at: fixedDate)
        #expect(cached.value == expected)
        #expect(try cached.release(validating: {}, effect: { $0 }) == expected)
        #expect(throws: OfflineReleaseError.alreadyConsumed) { try cached.release(validating: {}, effect: { $0 }) }
        #expect(await codec.decodeCount() == 1)
        #expect(live.deadlines().isEmpty)
    }

    @Test func cachedTOTPRetryValidatesReplacementUsernameIndependently() async throws {
        let totp = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let fixture = try await selectedFixture(totp: totp, username: "user")
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let stale = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let gate = OfflineTestGate()
        let codec = PostDecodeReplacementGateCodec(codec: fixture.codec, gate: gate, staleRevision: stale.identity.revision)
        let live = ResolverLive(error: .notLoggedIn, now: { clock.withLock { $0 } })
        let adapter = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: codec, readiness: fixture.service, now: { clock.withLock { $0 } }
        ))
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "user", serviceIdentifier: "example.test", hasTOTP: true
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: descriptor.username)
        let returnedValue = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            let value = try await adapter.resolve(descriptor: descriptor, kind: .oneTimeCode, context: context)
            returnedValue.withLock { $0 = true }
            return value
        }
        do {
            try await gate.waitUntilEntered()
            #expect(await codec.decodedRevisions() == [stale.identity.revision])
            #expect(await codec.usernameMatches() == [true])
            let request = try #require(try await fixture.repository.beginRequest(itemID: "item", vaultID: "vault", shareID: "share", kind: .refresh))
            let replacement = try await fixture.codec.prepareSnapshot(
                from: offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "replacement",
                                         username: "replacement@example.test", totp: totp), for: request
            )
            var committedReplacements = 0
            if try await fixture.repository.publish(replacement, for: request, refreshedAt: Date()) { committedReplacements += 1 }
            #expect(committedReplacements == 1)
            #expect(try await fixture.repository.authorizedSnapshot(for: key)?.identity.revision == replacement.snapshot.identity.revision)
            await gate.open()
            await #expect(throws: AutoFillSecretResolverError.usernameMismatch) { _ = try await task.value }
            #expect(await codec.decodedRevisions() == [stale.identity.revision, replacement.snapshot.identity.revision])
            #expect(await codec.usernameMatches() == [true, false])
            #expect(returnedValue.withLock { $0 } == false)
            #expect(live.deadlines().isEmpty)
            #expect(fixture.repository.releaseAuthority.registrationCount == 0)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test func cachedEmptyUsernameEmailMismatchRejectsPasswordAndTOTP() async throws {
        let totp = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=999999999"
        let fixture = try await selectedFixture(totp: totp, username: "", email: "different@example.test")
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let live = ResolverLive(error: .notLoggedIn, now: { clock.withLock { $0 } })
        let codec = DecodeCountingCodec(codec: fixture.codec)
        let adapter = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: live, repository: fixture.repository,
            codec: codec, readiness: fixture.service, now: { clock.withLock { $0 } }
        ))
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "",
            username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true
        )
        for kind in [AutoFillValueKind.password, .oneTimeCode] {
            let context = SecretResolutionContext(deadlineUptimeNanoseconds: clock.withLock { $0 + 4_000_000_000 },
                                                  expectedUsername: descriptor.username)
            var returnedValue = false
            await #expect(throws: AutoFillSecretResolverError.usernameMismatch) {
                _ = try await adapter.resolve(descriptor: descriptor, kind: kind, context: context)
                returnedValue = true
            }
            #expect(returnedValue == false)
        }
        #expect(await codec.decodeCount() == 2)
        #expect(live.deadlines().isEmpty)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test func cancellationAfterActualSnapshotDecryptionRejectsDecodedValue() async throws {
        let fixture = try await selectedFixture()
        let gate = OfflineTestGate()
        let codec = PostDecodeGateCodec(codec: fixture.codec, gate: gate)
        let live = ResolverLive(error: .notLoggedIn)
        let resolver = OfflineSecretResolver(
            live: live, repository: fixture.repository,
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
        #expect(live.callCount() == 0)
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
        try await fixture.repository.removeItem("item")
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
            itemType: .login, selectionGeneration: UUID(), metadataGeneration: UUID(), requestGeneration: UUID()
        )
        let replacement = try await fixture.codec.prepareSnapshot(
            from: offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "replacement"),
            for: request
        )
        let racingCodec = ReplacementRaceCodec(
            codec: fixture.codec, staleRevision: stale.identity.revision,
            database: fixture.database, replacement: replacement.snapshot
        )
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: racingCodec, readiness: fixture.service
        )

        let item = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        guard case .login(let login) = item.value.content.content else { Issue.record("expected login"); return }
        #expect(login.password == "replacement")
        #expect(try await fixture.repository.authorizedSnapshot(for: key)?.identity.revision == replacement.snapshot.identity.revision)
    }

    @Test("no-cache native overflow during timeout refuses decode and release", arguments: [false, true])
    func nativeTimeoutOverflowWithoutCacheNeverDecodesOrReleases(delayedNotification: Bool) async throws {
        let selected = try await selectedFixture()
        try await selected.repository.removeItem("item")
        let native = NativeTimeoutOverflowFixture(delayedNotification: delayedNotification)
        defer { native.removeMarkers() }
        let codec = DecodeCountingCodec(codec: selected.codec)
        let cli = PassCLIService(cliPath: "/bin/sh", runner: NativeTimeoutOverflowRunner(fixture: native))
        let resolver = OfflineSecretResolver(live: cli, repository: selected.repository, codec: codec, readiness: selected.service)
        let executor = CLIRunnerTestTaskExecutor()
        let originalDeadline = OSAllocatedUnfairLock(initialState: Optional<CLIExecutionDeadline>.none)
        let released = OSAllocatedUnfairLock(initialState: false)
        await #expect {
            try await withTaskExecutorPreference(executor) {
                let deadline = CLIExecutionDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
                originalDeadline.withLock { $0 = deadline }
                let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline.uptimeNanoseconds, expectedUsername: nil)
                _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
                released.withLock { $0 = true }
            }
        } throws: { error in
            guard let typed = error as? CLIError, case .outputLimitExceeded = typed else { return false }
            return true
        }
        #expect(await codec.decodeCount() == 0)
        #expect(released.withLock { $0 } == false)
        #expect(try await selected.repository.hasPersistedSnapshots() == false)
        await native.expectTimeoutTrapAndSingleCompletion()
        let expectedDeadline = try #require(originalDeadline.withLock { $0 })
        #expect(native.observedDeadlines().incoming.count == 1)
        #expect(native.observedDeadlines().incoming == [expectedDeadline])
        #expect(native.observedDeadlines().incoming == native.observedDeadlines().forwarded)
    }

    @Test func nativeAbsoluteDeadlineSurvivesSuspendedFixtureEntry() async throws {
        let gate = OfflineTestGate()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("qa-expired-deadline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let events = OSAllocatedUnfairLock(initialState: [CLIRunner.LifecycleTesting.Event]())
        let lifecycle = CLIRunner.LifecycleTesting(marker: { event in events.withLock { $0.append(event) } })
        let deadlineTime = DispatchTime.now() + .seconds(1)
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: deadlineTime.uptimeNanoseconds)
        let task = Task {
            try await gate.wait()
            return try await CLIRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", "printf launched > '\(marker.path)'"],
                deadline: deadline, maximumOutputBytes: 16 * 1024, lifecycleTesting: lifecycle
            )
        }
        // Exercise expiry before native entry, not a trap that requires the
        // child to start before expiry. Queueing must never renew this budget.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: deadlineTime)
        timer.setEventHandler { Task { await gate.open() } }
        timer.resume()
        defer { timer.cancel() }
        do {
            try await gate.waitUntilEntered()
            await #expect { _ = try await task.value } throws: { error in
                guard let error = error as? CLIError, case .timeout = error else { return false }
                return true
            }
            #expect(FileManager.default.fileExists(atPath: marker.path) == false)
            let observed = events.withLock { $0 }
            #expect(observed.contains(.deadlineCaptured))
            #expect(observed.contains(.launching) == false)
            #expect(observed.contains(.terminating) == false)
            #expect(observed.contains(.outputLimitNotificationCompleted) == false)
            #expect(observed.filter { $0 == .completed }.count == 1)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    private func selectedFixture(
        totp: String = "",
        username: String = "person@example.test",
        email: String = ""
    ) async throws -> SelectedResolverFixture {
        let repositoryFixture = try await withTaskExecutorPreference(FixtureSetupExecutor.shared) {
            try OfflineLifecycleFixture(itemIDs: ["item"])
        }
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
