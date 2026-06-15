import Foundation
import Testing
@testable import Quick_Access_for_Pass

@MainActor
struct PassCLIPATCredentialStoreTests {
    @Test(.timeLimit(.minutes(1)))
    func saveLoadHasAndDeleteToken() async throws {
        let serviceName = "codes.petr.quick-access-for-pass.tests.pat.\(UUID().uuidString)"
        let store = KeychainPassCLIPATCredentialStore(serviceName: serviceName)

        #expect(await store.hasToken() == false)
        #expect(try await store.loadToken() == nil)

        try await store.saveToken("pst_test_token::secret")

        #expect(await store.hasToken() == true)
        #expect(try await store.loadToken() == "pst_test_token::secret")

        try await store.deleteToken()

        #expect(await store.hasToken() == false)
        #expect(try await store.loadToken() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func saveTokenUpdatesExistingToken() async throws {
        let serviceName = "codes.petr.quick-access-for-pass.tests.pat.\(UUID().uuidString)"
        let store = KeychainPassCLIPATCredentialStore(serviceName: serviceName)

        try await store.saveToken("first-token")
        try await store.saveToken("second-token")

        #expect(try await store.loadToken() == "second-token")

        try await store.deleteToken()
    }
}
