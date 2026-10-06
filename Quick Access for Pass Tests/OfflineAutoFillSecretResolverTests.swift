import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline AutoFill secret resolver", .timeLimit(.minutes(1)))
struct OfflineAutoFillSecretResolverTests {
    @Test func verifiedAutoFillPasswordUsesOnlyTheRequestedResolvedValue() async throws {
        let resolver = OfflineAutoFillSecretResolver(resolver: AutoFillPasswordResolver())
        #expect(try await resolver.resolve(descriptor: descriptor, kind: .password) == "cached-password")
    }

    @Test func authorizedSnapshotSuppliesPasswordWhenLiveIsUnavailable() async throws {
        let fixture = try await makeFixture()
        let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)
        #expect(try await resolver.resolve(descriptor: descriptor, kind: .password) == "cached-password")
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

    @Test func authorizedEncryptedSnapshotSuppliesTOTPWithDeterministicFixtureData() async throws {
        let uri = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999"
        let fixture = try await makeFixture(totp: uri)
        let resolver = OfflineAutoFillSecretResolver(resolver: fixture.resolver)

        let code = try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode)
        let expected = try TOTPGenerator.code(from: uri, at: Date(timeIntervalSince1970: 1_000_000_000))
        #expect(code == expected)
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

        #expect(try await resolver.resolve(descriptor: passwordDescriptor, kind: .password) == "cached-password")
        #expect(try await resolver.resolve(descriptor: totpDescriptor, kind: .oneTimeCode) == "123456")
    }

    @Test func selectedSnapshotReservesOneSecondForFallbackButLiveOnlyKeepsRemainingBudget() throws {
        let deadline: UInt64 = 10_000_000_000
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline, expectedUsername: "user")
        #expect(try OfflineAutoFillLiveBudget.timeout(context: context, hasSnapshot: true, now: 6_000_000_000) == 2)
        #expect(try OfflineAutoFillLiveBudget.timeout(context: context, hasSnapshot: false, now: 6_000_000_000) == 4)
        #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try OfflineAutoFillLiveBudget.timeout(context: context, hasSnapshot: true, now: 9_000_000_000)
        }
    }

    private func makeFixture(totp: String = "") async throws -> AutoFillFixture {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let codec = fixture.codec()
        let service = OfflineModeService(repository: fixture.repository, codec: codec, cliService: AutoFillViewer(totp: totp))
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        #expect(try await fixture.repository.offlineVaultIds().isEmpty)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "item")?.isManuallySelected == true)
        return AutoFillFixture(resolver: OfflineSecretResolver(
            live: AutoFillLive(), repository: fixture.repository, codec: codec, readiness: service
        ))
    }

    private var descriptor: AutoFillCredentialDescriptor {
        AutoFillCredentialDescriptor(id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "", username: "person@example.test", serviceIdentifier: "example.com", hasTOTP: false)
    }

    private var totpDescriptor: AutoFillCredentialDescriptor {
        AutoFillCredentialDescriptor(id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "", username: "person@example.test", serviceIdentifier: "example.com", hasTOTP: true)
    }
}

private struct AutoFillFixture { let resolver: OfflineSecretResolver }
private struct AutoFillNotReady: OfflineInitializationProviding { func isReady() async -> Bool { false } }
private struct AutoFillLive: OfflineSecretResolvingLive {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.notLoggedIn }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.notLoggedIn }
}
private struct AutoFillViewer: OfflineItemViewing {
    let totp: String

    init(totp: String = "") { self.totp = totp }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId, password: "cached-password", totp: totp
        )
    }
}
private struct AutoFillPasswordResolver: SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "cached-password")
    }
    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String { "000000" }
}

private struct EmailFallbackResolver: SecretItemResolving {
    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
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
        return try JSONDecoder().decode(CLIItem.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        "123456"
    }
}

private actor CancellationIgnoringAutoFillResolver: SecretItemResolving {
    private let gate: OfflineTestGate

    init(gate: OfflineTestGate) { self.gate = gate }

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "unused")
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        try? await gate.wait()
        return "00000000"
    }
}

private actor TOTPCallRecorder: SecretItemResolving {
    private var calls = 0

    func resolveItem(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> CLIItem {
        try offlineTestCLIItem(id: itemId, vaultID: vaultId, shareID: shareId, password: "unused")
    }

    func resolveTOTP(itemId: String, vaultId: String, shareId: String, context: SecretResolutionContext) async throws -> String {
        calls += 1
        return "00000000"
    }

    func totpCalls() -> Int { calls }
}
