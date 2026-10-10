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

    @Test func selectedLivePhaseDeadlineRetainsFallbackReserveWithoutClockRefresh() throws {
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 5_000_000_000, expectedUsername: nil)
        #expect(try OfflineAutoFillLiveBudget.deadline(context: context, hasSnapshot: false, now: 1_000_000_000)?.uptimeNanoseconds == 5_000_000_000)
        #expect(try OfflineAutoFillLiveBudget.deadline(context: context, hasSnapshot: true, now: 1_000_000_000)?.uptimeNanoseconds == 3_000_000_000)
        let nearOverflow = SecretResolutionContext(deadlineUptimeNanoseconds: UInt64.max, expectedUsername: nil)
        #expect(try OfflineAutoFillLiveBudget.deadline(context: nearOverflow, hasSnapshot: true, now: UInt64.max - 1_500_000_000)?.uptimeNanoseconds == UInt64.max - 1_000_000_000)
        let noReserve = SecretResolutionContext(deadlineUptimeNanoseconds: 2_000_000_000, expectedUsername: nil)
        do {
            _ = try OfflineAutoFillLiveBudget.deadline(context: noReserve, hasSnapshot: true, now: 1_000_000_000)
            Issue.record("selected deadline without fallback reserve should fail")
        } catch let error as SecretResolutionError {
            guard case .deadlineExpired = error else { Issue.record("unexpected secret resolution error"); return }
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
        let resolver = OfflineSecretResolver(live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
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
    }

    @Test func replacementDuringDecodeRetriesWithFreshCaptureAndPayload() async throws {
        let fixture = try await selectedFixture()
        let gate = OfflineTestGate()
        let resolver = OfflineSecretResolver(live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
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
    }

    @Test @MainActor func liveAndUnrelatedCachedValuesSurvivePendingRealRemoval() async throws {
        let gate = OfflineTestGate()
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target", "neighbor"], offlineMutationTesting: OfflineMutationTesting(afterAdmission: { scope in
            if case .itemID("target") = scope { try? await gate.wait() }
        }))
        let service = fixture.service()
        try await initializeOfflineFixtureService(service)
        for item in fixture.items { try await service.makeAvailableOffline(item: item, shareId: "share") }
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

    @Test func liveItemWinsOverAuthorizedSnapshot() async throws {
        let fixture = try await selectedFixture()
        let resolver = OfflineSecretResolver(
            live: ResolverLive(item: try offlineTestCLIItem(id: "item", vaultID: "vault", shareID: "share", password: "live")),
            repository: fixture.repository,
            codec: fixture.codec,
            readiness: fixture.service
        )

        let value = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        guard case .login(let login) = value.value.content.content else { Issue.record("expected login"); return }
        #expect(login.password == "live")
    }

    @Test func unavailableLiveTOTPUsesAuthorizedEncryptedSnapshot() async throws {
        let fixture = try await selectedFixture(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8")
        let resolver = OfflineSecretResolver(
            live: ResolverLive(error: .notLoggedIn), repository: fixture.repository,
            codec: fixture.codec, readiness: fixture.service
        )
        #expect(try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share").value.count == 8)
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
        #expect(live.deadlines().count == 1)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
        // The same injected clock remains authoritative when it really expires.
        clock.withLock { $0 = 5_000_000_000 }
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        #expect(await codec.decodeCount() == 1)
        #expect(live.deadlines().count == 1)
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

    @Test func postPhaseParseFailureDoesNotDecodeFallbackSnapshotForComposedTOTP() async throws {
        let fixture = try await selectedFixture(
            totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=999999999"
        )
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
        #expect(await live.deadlines() == [3_000_000_000, 3_000_000_000])
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
        #expect(live.deadlines().count == 1)
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
            #expect(try await fixture.repository.authorizedSnapshot(for: key)?.identity.revision == replacement.identity.revision)
            await gate.open()
            await #expect(throws: AutoFillSecretResolverError.usernameMismatch) { _ = try await task.value }
            #expect(await codec.decodedRevisions() == [stale.identity.revision, replacement.identity.revision])
            #expect(await codec.usernameMatches() == [true, false])
            #expect(returnedValue.withLock { $0 } == false)
            #expect(live.deadlines().count == 1)
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
        #expect(live.deadlines().count == 2)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
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
        guard case .login(let login) = item.value.content.content else { Issue.record("expected login"); return }
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
        #expect(native.observedDeadlines().incoming.count == 1)
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
    private let now: @Sendable () -> UInt64
    private let recordedDeadlines = OSAllocatedUnfairLock<[CLIExecutionDeadline]>(initialState: [])
    init(item: CLIItem? = nil, error: CLIError? = nil,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.item = item
        self.error = error
        self.now = now
    }
    func deadlines() -> [CLIExecutionDeadline] { recordedDeadlines.withLock { $0 } }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        try Task.checkCancellation()
        _ = try deadline.remainingSeconds(at: now())
        recordedDeadlines.withLock { $0.append(deadline) }
        return try await viewItem(itemId: itemId, shareId: shareId)
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        try Task.checkCancellation()
        _ = try deadline.remainingSeconds(at: now())
        recordedDeadlines.withLock { $0.append(deadline) }
        return try await getTotp(itemId: itemId, shareId: shareId)
    }
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
    private var calls = 0
    private let now: @Sendable () -> UInt64

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) { self.now = now }
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        calls += 1
        return try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "live")
    }
    func getTotp(itemId: String, shareId: String) async throws -> String { calls += 1; return "000000" }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { recorded.append(timeout); return try await viewItem(itemId: itemId, shareId: shareId) }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { recorded.append(timeout); calls += 1; return "000000" }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        let remaining = try deadline.remainingSeconds(at: now())
        recorded.append(remaining)
        return try await viewItem(itemId: itemId, shareId: shareId)
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        recorded.append(try deadline.remainingSeconds(at: now()))
        calls += 1
        return "000000"
    }
    func timeouts() -> [TimeInterval] { recorded }
    func callCount() -> Int { calls }
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

    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        recorded.append(try deadline.remainingSeconds(at: clock.withLock { $0 }))
        clock.withLock { $0 = 5_000_000_000 }
        return try await viewItem(itemId: itemId, shareId: shareId)
    }

    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        recorded.append(try deadline.remainingSeconds(at: clock.withLock { $0 }))
        return "000000"
    }

    func timeouts() -> [TimeInterval] { recorded }
}

private actor ComposedTOTPParseFailureLive: OfflineSecretResolvingLive {
    private let clock: OSAllocatedUnfairLock<UInt64>
    private var callDeadlines: [UInt64] = []

    init(clock: OSAllocatedUnfairLock<UInt64>) { self.clock = clock }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        callDeadlines.append(deadline.uptimeNanoseconds)
        clock.withLock { $0 = 2_500_000_000 }
        return try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId, password: "live",
            totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=999999999"
        )
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        callDeadlines.append(deadline.uptimeNanoseconds)
        clock.withLock { $0 = 3_100_000_000 }
        throw CLIError.parseError("malformed")
    }
    func deadlines() -> [UInt64] { callDeadlines }
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

private actor PostDecodeReplacementGateCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private let gate: OfflineTestGate
    private let staleRevision: UUID
    private var revisions: [UUID] = []
    private var matches: [Bool] = []

    init(codec: OfflineSnapshotCodec, gate: OfflineTestGate, staleRevision: UUID) {
        self.codec = codec
        self.gate = gate
        self.staleRevision = staleRevision
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        let item = try await codec.decodeSnapshot(snapshot)
        revisions.append(snapshot.identity.revision)
        if case .login(let login) = item.content.content { matches.append(login.username == "user") }
        else { matches.append(false) }
        if revisions.count == 1, snapshot.identity.revision == staleRevision { try await gate.wait() }
        return item
    }

    func decodedRevisions() -> [UUID] { revisions }
    func usernameMatches() -> [Bool] { matches }
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

extension OfflineSecretResolverTests {
    @Test func liveOnlyResolverForwardsOriginalDeadlineForItemAndTOTP() async throws {
        let runner = LiveOnlyDeadlineRunner()
        let resolver = LiveSecretItemResolver(cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner))
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline.uptimeNanoseconds, expectedUsername: nil)
        await #expect(throws: CLIError.self) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        await #expect(throws: CLIError.self) {
            _ = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        #expect(await runner.observedDeadlines() == [deadline, deadline])
        #expect(await runner.relativeCallCount() == 0)
    }

    @Test func liveOnlyCombinedAutoFillDelegatesBothCommandsWithOriginalDeadline() async throws {
        let runner = LiveOnlyComposedDeadlineRunner()
        let resolver = LiveSecretItemResolver(cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner))
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline.uptimeNanoseconds, expectedUsername: "person@example.test")

        let result = try await resolver.resolveAutoFillValue(
            itemId: "item", vaultId: "vault", shareId: "share", kind: .oneTimeCode, context: context
        )
        #expect(result.value == "246810")
        #expect(result.offlineCapability == nil)
        #expect(await runner.observedDeadlines() == [deadline, deadline])
    }

    @Test func liveOnlyResolverRejectsExpiredItemAndTOTPDeadlinesBeforeRunner() async throws {
        let runner = LiveOnlyDeadlineRunner()
        let resolver = LiveSecretItemResolver(cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner))
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 0, expectedUsername: nil)
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        #expect(await runner.observedDeadlines().isEmpty)
        #expect(await runner.relativeCallCount() == 0)
    }
}

private actor LiveOnlyComposedDeadlineRunner: CLIRunning {
    private var deadlines: [CLIExecutionDeadline] = []

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data { throw CLIError.timeout }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data { throw CLIError.timeout }
    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        deadlines.append(deadline)
        if arguments.contains("totp") {
            return Data("{\"totp_uri\":\"otpauth://redacted\",\"totp\":\"246810\"}".utf8)
        }
        return Data("""
        {
          "item": {
            "id": "item", "share_id": "share", "vault_id": "vault",
            "content": {
              "title": "Fixture", "note": "", "item_uuid": "fixture",
              "content": {
                "Login": {
                  "username": "person@example.test", "email": "", "password": "not-released",
                  "totp_uri": "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "urls": []
                }
              },
              "extra_fields": []
            },
            "state": "Active", "flags": [], "create_time": "", "modify_time": ""
          }
        }
        """.utf8)
    }
    func observedDeadlines() -> [CLIExecutionDeadline] { deadlines }
}

private actor LiveOnlyDeadlineRunner: CLIRunning {
    private var deadlines: [CLIExecutionDeadline] = []
    private var relativeCalls = 0

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        relativeCalls += 1
        throw CLIError.notLoggedIn
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        relativeCalls += 1
        throw CLIError.notLoggedIn
    }

    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        deadlines.append(deadline)
        throw CLIError.notLoggedIn
    }

    func observedDeadlines() -> [CLIExecutionDeadline] { deadlines }
    func relativeCallCount() -> Int { relativeCalls }
}
