import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline AutoFill secret resolver", .timeLimit(.minutes(1)))
struct OfflineAutoFillSecretResolverTests {
    @Test func verifiedAutoFillPasswordUsesOnlyTheRequestedResolvedValue() async throws {
        let resolver = OfflineAutoFillSecretResolver(resolver: AutoFillPasswordResolver())
        #expect(try await resolver.resolve(descriptor: descriptor, kind: .password).value == "cached-password")
    }

    @Test func authorizedSnapshotSuppliesPasswordWhenLiveIsUnavailable() async throws {
        let fixture = try await makeFixture()
        let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)
        #expect(try await resolver.resolve(descriptor: descriptor, kind: .password).value == "cached-password")
    }

    @Test func unreadyOrUnselectedSnapshotsNeverSatisfyAutoFillFallback() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let resolver = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: AutoFillLive(), repository: fixture.repository, codec: fixture.codec(), readiness: AutoFillNotReady()
        ))
        await #expect {
            _ = try await resolver.resolve(descriptor: descriptor, kind: .password)
        } throws: { error in
            guard let error = error as? CLIError, case .notLoggedIn = error else { return false }
            return true
        }
    }

    @Test func selectedShortBudgetTOTPDoesNotStartLiveTOTPAfterItemFailure() async throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let live = ShortBudgetAutoFillLive(clock: clock)
        let fixture = try await makeFixture(
            totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999",
            live: live,
            now: { clock.withLock { $0 } }
        )
        let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: "person@example.test")

        let result = try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode, context: context)
        #expect(result.value.count == 8)
        #expect(result.value != "00000000")
        #expect(await live.totpCalls() == 0)
    }

    @Test func queuedTOTPRetainsOriginalLivePhaseDeadlineAfterExecutorDelay() async throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let gate = OfflineTestGate()
        let live = GatedExecutorDelayLive(clock: clock, gate: gate)
        let fixture = try await makeFixture(totp: cachedTOTPURI, live: live, now: { clock.withLock { $0 } }, selected: false)
        let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 10_000_000_000, expectedUsername: "person@example.test")
        let task = Task { try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode, context: context) }

        do {
            try await gate.waitUntilEntered()
            #expect(await live.observedDeadlines() == [10_000_000_000, 10_000_000_000])
            #expect(await live.totpBudgetAtQueue() == 7_500_000_000)
            clock.withLock { $0 = 10_100_000_000 }
            await gate.open()
            await #expect(throws: SecretResolutionError.deadlineExpired) { _ = try await task.value }
            #expect(await fixture.codec.decodeCount() == 0)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test func separateCachedActionsDoNotConsumeLivePhaseBudget() async throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let live = ShortBudgetAutoFillLive(clock: clock)
        let fixture = try await makeFixture(totp: cachedTOTPURI, live: live, now: { clock.withLock { $0 } })
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: "person@example.test")

        let cachedItem = try await fixture.resolver.resolveItem(
            itemId: "item", vaultId: "vault", shareId: "share", context: context
        )
        #expect(cachedItem.value.id == "item")
        let code = try await fixture.resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        #expect(code.offlineCapability != nil)
        #expect(clock.withLock { $0 } == 1_000_000_000)
        #expect(await live.totpCalls() == 0)
    }

    @Test func cachedTOTPDoesNotStartEitherLiveCommand() async throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let live = ItemThenTOTPTimeoutLive(clock: clock)
        let fixture = try await makeFixture(
            totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999",
            live: live,
            now: { clock.withLock { $0 } }
        )
        let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: "person@example.test")

        let result = try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode, context: context)
        #expect(result.value.count == 8)
        #expect(await live.observedDeadlines().isEmpty)
        #expect(clock.withLock { $0 } == 1_000_000_000)
    }

    @Test func ineligibleItemAndPostPhaseTOTPFailuresNeverDecodeSnapshot() async throws {
        let errors: [CLIError] = [
            .parseError("malformed"), .outputLimitExceeded, .commandFailed("failed")
        ]
        for failure in errors {
            let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
            let live = PhaseFailureAutoFillLive(clock: clock, itemFailure: failure)
            let fixture = try await makeFixture(totp: cachedTOTPURI, live: live, now: { clock.withLock { $0 } }, selected: false)
            let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)
            let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: "person@example.test")
            await #expect(throws: CLIError.self) {
                _ = try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode, context: context)
            }
            #expect(await fixture.codec.decodeCount() == 0)
            #expect(fixture.repository.releaseAuthority.registrationCount == 0)
        }

        for failure in errors {
            let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
            let live = PhaseFailureAutoFillLive(clock: clock, totpFailure: failure)
            let fixture = try await makeFixture(totp: cachedTOTPURI, live: live, now: { clock.withLock { $0 } }, selected: false)
            let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)
            let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: "person@example.test")
            await #expect(throws: CLIError.self) {
                _ = try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode, context: context)
            }
            #expect(await fixture.codec.decodeCount() == 0)
            #expect(fixture.repository.releaseAuthority.registrationCount == 0)
        }
    }

    @Test func originalExpiryIsTerminalWhileCacheNeedsNoReserve() async throws {
        let originalExpiryClock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let expiredLive = PhaseFailureAutoFillLive(clock: originalExpiryClock, itemFailure: .timeout, expireOriginalDeadline: true)
        let expiredFixture = try await makeFixture(totp: cachedTOTPURI, live: expiredLive, now: { originalExpiryClock.withLock { $0 } }, selected: false)
        let expiredResolver = OfflineAutoFillSecretResolver(resolver: expiredFixture.resolver)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: "person@example.test")
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await expiredResolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode, context: context)
        }
        #expect(await expiredFixture.codec.decodeCount() == 0)
        #expect(expiredFixture.repository.releaseAuthority.registrationCount == 0)

        let reserveClock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reserveLive = PhaseFailureAutoFillLive(clock: reserveClock)
        let reserveFixture = try await makeFixture(totp: cachedTOTPURI, live: reserveLive, now: { reserveClock.withLock { $0 } })
        let reserveResolver = OfflineAutoFillSecretResolver(resolver: reserveFixture.resolver)
        let insufficient = SecretResolutionContext(deadlineUptimeNanoseconds: 2_000_000_000, expectedUsername: "person@example.test")
        let result = try await reserveResolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode, context: insufficient)
        #expect(result.offlineCapability != nil)
        #expect(await reserveLive.itemCalls() == 0)
        #expect(await reserveFixture.codec.decodeCount() == 1)
        #expect(reserveFixture.repository.releaseAuthority.registrationCount == 1)
    }

    @Test func liveIdentityCannotAuthorizeMismatchedCachedTOTPIdentity() async throws {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let live = ItemThenTOTPTimeoutLive(clock: clock, itemUsername: "person@example.test")
        let fixture = try await makeFixture(
            totp: cachedTOTPURI, username: "different@example.test", live: live, now: { clock.withLock { $0 } }
        )
        let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 4_000_000_000, expectedUsername: "person@example.test")
        await #expect(throws: AutoFillSecretResolverError.usernameMismatch) {
            _ = try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode, context: context)
        }
        #expect(await fixture.codec.decodeCount() == 1)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test func authorizedEncryptedSnapshotSuppliesTOTPWithDeterministicFixtureData() async throws {
        let uri = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999"
        let fixture = try await makeFixture(totp: uri)
        let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)

        let code = try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode)
        let expected = try TOTPGenerator.code(from: uri, at: Date(timeIntervalSince1970: 1_000_000_000))
        #expect(code.value == expected)
    }

    @Test func cancelledResolutionRejectsValueFromCancellationIgnoringResolver() async throws {
        let gate = OfflineTestGate()
        let resolver = OfflineAutoFillSecretResolver(resolver: CancellationIgnoringAutoFillResolver(gate: gate))
        let task = Task { try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode) }
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

    @Test func legacyResolverRejectsAutoFillWithoutReleasingUnvalidatedTOTP() async throws {
        let fetchCalls = OSAllocatedUnfairLock(initialState: 0)
        let resolver = LegacySecretItemResolver(
            fetchItem: { itemId, shareId in
                fetchCalls.withLock { $0 += 1 }
                return try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "unused")
            },
            cliService: PassCLIService(cliPath: "/unused/pass-cli")
        )
        await #expect(throws: AutoFillSecretResolverError.unsupportedResolver) {
            _ = try await resolver.resolveAutoFillValue(
                itemId: "item", vaultId: "vault", shareId: "share", kind: .oneTimeCode,
                context: SecretResolutionContext(deadlineUptimeNanoseconds: nil, expectedUsername: "other@example.test")
            )
        }
        #expect(fetchCalls.withLock { $0 } == 0)
    }

    @Test func descriptorWithoutTOTPCapabilityIsRejectedBeforeFallback() async throws {
        let resolver = TOTPCallRecorder()
        let adapter = OfflineAutoFillSecretResolver(resolver: resolver)

        await #expect(throws: AutoFillSecretResolverError.descriptorDoesNotSupportValue) {
            _ = try await adapter.resolve(descriptor: descriptor, kind: .oneTimeCode)
        }
        #expect(await resolver.totpCalls() == 0)
    }

    @Test func emailFallbackMatchesTheVerifiedDescriptorForPasswordAndTOTP() async throws {
        let resolver = OfflineAutoFillSecretResolver(resolver: EmailFallbackResolver())
        let passwordDescriptor = descriptor
        let totpDescriptor = AutoFillCredentialDescriptor(
            id: passwordDescriptor.id, vaultID: passwordDescriptor.vaultID, itemID: passwordDescriptor.itemID,
            shareID: passwordDescriptor.shareID, title: passwordDescriptor.title, username: passwordDescriptor.username,
            serviceIdentifier: passwordDescriptor.serviceIdentifier, hasTOTP: true
        )

        #expect(try await resolver.resolve(descriptor: passwordDescriptor, kind: .password).value == "cached-password")
        #expect(try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode).value == "123456")
    }

    @Test func liveBudgetDoesNotReserveTimeForCacheFallback() throws {
        let deadline: UInt64 = 10_000_000_000
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline, expectedUsername: "user")
        #expect(try OfflineAutoFillLiveBudget.timeout(context: context, now: 6_000_000_000) == 4)
        #expect(try OfflineAutoFillLiveBudget.timeout(context: context, now: 9_000_000_000) == 1)
    }

    private func makeFixture(
        totp: String = "",
        username: String = "person@example.test",
        live: any OfflineSecretResolvingLive = AutoFillLive(),
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        selected: Bool = true
    ) async throws -> AutoFillFixture {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let codec = fixture.codec()
        let service = OfflineModeService(repository: fixture.repository, codec: codec, cliService: AutoFillViewer(totp: totp, username: username))
        try await initializeOfflineFixtureService(service)
        if selected { try await service.makeAvailableOffline(item: item, shareId: "share") }
        #expect(try await fixture.repository.offlineVaultIds().isEmpty)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item")?.isManuallySelected == (selected ? true : nil))
        let countingCodec = CountingAutoFillCodec(codec: codec)
        return AutoFillFixture(resolver: OfflineSecretResolver(
            live: live, repository: fixture.repository, codec: countingCodec, readiness: service, now: now
        ), repository: fixture.repository, codec: countingCodec)
    }

    private var descriptor: AutoFillCredentialDescriptor {
        AutoFillCredentialDescriptor(id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "", username: "person@example.test", serviceIdentifier: "example.com", hasTOTP: false)
    }

    private var totpDescriptor: AutoFillCredentialDescriptor {
        AutoFillCredentialDescriptor(id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "", username: "person@example.test", serviceIdentifier: "example.com", hasTOTP: true)
    }
}

private let cachedTOTPURI = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999"

private struct AutoFillFixture {
    let resolver: OfflineSecretResolver
    let repository: OfflineSnapshotRepository
    let codec: CountingAutoFillCodec
}

private actor CountingAutoFillCodec: OfflineSnapshotCoding {
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

private actor GatedExecutorDelayLive: OfflineSecretResolvingLive {
    private let clock: OSAllocatedUnfairLock<UInt64>
    private let gate: OfflineTestGate
    private var deadlines: [UInt64] = []
    private var totpRemainingAtQueue: UInt64?

    init(clock: OSAllocatedUnfairLock<UInt64>, gate: OfflineTestGate) {
        self.clock = clock
        self.gate = gate
    }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        deadlines.append(deadline.uptimeNanoseconds)
        clock.withLock { $0 = 2_500_000_000 }
        return try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId, password: "live", totp: cachedTOTPURI
        )
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        let now = clock.withLock { $0 }
        deadlines.append(deadline.uptimeNanoseconds)
        totpRemainingAtQueue = deadline.uptimeNanoseconds - now
        try await gate.wait()
        throw CLIError.timeout
    }
    func observedDeadlines() -> [UInt64] { deadlines }
    func totpBudgetAtQueue() -> UInt64? { totpRemainingAtQueue }
}

private actor ItemThenTOTPTimeoutLive: OfflineSecretResolvingLive {
    private let clock: OSAllocatedUnfairLock<UInt64>
    private let itemUsername: String
    private var deadlines: [UInt64] = []

    init(clock: OSAllocatedUnfairLock<UInt64>, itemUsername: String = "person@example.test") {
        self.clock = clock
        self.itemUsername = itemUsername
    }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        deadlines.append(deadline.uptimeNanoseconds)
        clock.withLock { $0 = 2_500_000_000 }
        return try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId, password: "live", username: itemUsername,
            totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999"
        )
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        deadlines.append(deadline.uptimeNanoseconds)
        clock.withLock { $0 = 3_100_000_000 }
        throw CLIError.timeout
    }
    func observedDeadlines() -> [UInt64] { deadlines }
}

private actor PhaseFailureAutoFillLive: OfflineSecretResolvingLive {
    private let clock: OSAllocatedUnfairLock<UInt64>
    private let itemFailure: CLIError?
    private let totpFailure: CLIError?
    private let expireOriginalDeadline: Bool
    private var itemCallCount = 0

    init(clock: OSAllocatedUnfairLock<UInt64>, itemFailure: CLIError? = nil, totpFailure: CLIError? = nil, expireOriginalDeadline: Bool = false) {
        self.clock = clock
        self.itemFailure = itemFailure
        self.totpFailure = totpFailure
        self.expireOriginalDeadline = expireOriginalDeadline
    }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        itemCallCount += 1
        if let itemFailure {
            clock.withLock { $0 = expireOriginalDeadline ? 4_000_000_000 : 3_100_000_000 }
            throw itemFailure
        }
        clock.withLock { $0 = 2_500_000_000 }
        return try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "live", totp: cachedTOTPURI)
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        clock.withLock { $0 = 3_100_000_000 }
        if let totpFailure { throw totpFailure }
        throw CLIError.timeout
    }
    func itemCalls() -> Int { itemCallCount }
}

private actor ShortBudgetAutoFillLive: OfflineSecretResolvingLive {
    private let clock: OSAllocatedUnfairLock<UInt64>
    private var totpCallCount = 0

    init(clock: OSAllocatedUnfairLock<UInt64>) { self.clock = clock }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String) async throws -> String { totpCallCount += 1; throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.timeout }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { totpCallCount += 1; throw CLIError.timeout }
    func viewItem(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> CLIItem {
        #expect(deadline.uptimeNanoseconds == 4_000_000_000)
        clock.withLock { $0 = 3_100_000_000 }
        throw CLIError.timeout
    }
    func getTotp(itemId: String, shareId: String, deadline: CLIExecutionDeadline) async throws -> String {
        totpCallCount += 1
        Issue.record("live TOTP must not be invoked after item lookup failed")
        throw CLIError.timeout
    }
    func totpCalls() -> Int { totpCallCount }
}
private struct AutoFillNotReady: OfflineInitializationProviding { func isReady() async -> Bool { false } }
private struct AutoFillLive: OfflineSecretResolvingLive {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.notLoggedIn }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.notLoggedIn }
}
private struct AutoFillViewer: OfflineItemViewing {
    let totp: String
    let username: String

    init(totp: String = "", username: String = "person@example.test") {
        self.totp = totp
        self.username = username
    }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId, password: "cached-password", username: username, totp: totp
        )
    }
}
private struct AutoFillPasswordResolver: SecretItemResolving {
    func resolveAutoFillValue(itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        switch kind {
        case .password: return ResolvedSecret(value: "cached-password", offlineCapability: nil)
        case .oneTimeCode: return ResolvedSecret(value: "000000", offlineCapability: nil)
        }
    }
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        return ResolvedSecret(value: try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "cached-password"), offlineCapability: nil)
    }
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        return ResolvedSecret(value: "000000", offlineCapability: nil)
    }
}

private struct EmailFallbackResolver: SecretItemResolving {
    func resolveAutoFillValue(itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        switch kind {
        case .password: return ResolvedSecret(value: "cached-password", offlineCapability: nil)
        case .oneTimeCode: return ResolvedSecret(value: "123456", offlineCapability: nil)
        }
    }
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        let object: [String: Any] = [
            "id": itemId, "vault_id": vaultId, "share_id": shareId, "state": "Active", "flags": [],
            "create_time": "", "modify_time": "",
            "content": [
                "title": "Offline example", "note": "", "item_uuid": "content-\(itemId)",
                "content": ["Login": [
                    "username": "", "email": "person@example.test", "password": "cached-password",
                    "totp_uri": "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "urls": []
                ]]
            ]
        ]
        return ResolvedSecret(value: try JSONDecoder().decode(CLIItem.self, from: JSONSerialization.data(withJSONObject: object)), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        return ResolvedSecret(value: "123456", offlineCapability: nil)
    }
}

private actor CancellationIgnoringAutoFillResolver: SecretItemResolving {
    func resolveAutoFillValue(itemId: String, vaultId: String, shareId: String, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        try? await gate.wait()
        return ResolvedSecret(value: "00000000", offlineCapability: nil)
    }
    private let gate: OfflineTestGate

    init(gate: OfflineTestGate) { self.gate = gate }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        return ResolvedSecret(value: try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "unused"), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        try? await gate.wait()
        return ResolvedSecret(value: "00000000", offlineCapability: nil)
    }
}

private actor TOTPCallRecorder: SecretItemResolving {
    private var calls = 0

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<CLIItem> {
        return ResolvedSecret(value: try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "unused"), offlineCapability: nil)
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        calls += 1
        return ResolvedSecret(value: "00000000", offlineCapability: nil)
    }

    func totpCalls() -> Int { calls }
}
