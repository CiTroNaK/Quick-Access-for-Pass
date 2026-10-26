import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder-selected cached resolver releases", .timeLimit(.minutes(1)))
struct OfflineFolderResolverTests {
    @Test("Ordinary mapped releases preserve a child policy and revoke with the last policy")
    func ordinaryRelease() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        _ = try await fixture.select("child")
        try await fixture.cache(parent)
        let service = try await fixture.service(viewer: OfflineFixtureViewer())
        let live = FolderResolverLive()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository, codec: fixture.codec(), readiness: service)
        fixture.gate.confirm(capabilities: .init(rawVersionString: "2.4.2"), for: fixture.gate.beginProbe())
        let item = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        let password = try item.map { item -> String in
            guard case .login(let login) = item.content.content else { throw AutoFillSecretResolverError.itemIsNotLogin }
            return login.password
        }
        _ = try await fixture.select("parent", selected: false)
        try password.release(validating: {}, effect: { #expect($0 == "synthetic") })
        let obsolete = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share")
        _ = try await fixture.select("child", selected: false)
        #expect(throws: OfflineReleaseError.revoked) {
            try obsolete.release(validating: {}, effect: { _ in Issue.record("Revoked folder release") })
        }
        #expect(await live.callCount() == 0)
        await service.stop()
    }

    @Test("AutoFill password and TOTP retain cache preference and final revocation", arguments: [AutoFillValueKind.password, .oneTimeCode])
    func autoFillRelease(kind: AutoFillValueKind) async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent, totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=30")
        let service = try await fixture.service(viewer: OfflineFixtureViewer())
        let live = FolderResolverLive()
        let resolver = OfflineSecretResolver(live: live, repository: fixture.repository, codec: fixture.codec(), readiness: service,
                                             totpDate: { Date(timeIntervalSince1970: 59) })
        fixture.gate.confirm(capabilities: .init(rawVersionString: "2.4.2"), for: fixture.gate.beginProbe())
        let descriptor = AutoFillCredentialDescriptor(id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "Synthetic",
            username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true)
        let result = try await OfflineAutoFillSecretResolver(resolver: resolver).resolve(descriptor: descriptor, kind: kind)
        #expect(result.offlineCapability != nil)
        #expect(result.value == (kind == .password ? "synthetic" : "94287082"))
        #expect(await live.callCount() == 0)
        _ = try await fixture.select("parent", selected: false)
        #expect(throws: OfflineReleaseError.revoked) {
            try result.release(validating: {}, effect: { _ in Issue.record("Revoked AutoFill folder release") })
        }
        await service.stop()
    }
}

private actor FolderResolverLive: OfflineSecretResolvingLive {
    private var calls = 0
    func callCount() -> Int { calls }
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { calls += 1; throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String) async throws -> String { calls += 1; throw CLIError.notLoggedIn }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem {
        try await viewItem(itemId: itemId, shareId: shareId)
    }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String {
        try await getTotp(itemId: itemId, shareId: shareId)
    }
}
