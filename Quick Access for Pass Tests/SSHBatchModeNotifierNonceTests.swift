import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("SSHBatchModeNotifier nonce hardening")
struct SSHBatchModeNotifierNonceTests {
    @Test func nonceIsIncludedInNotificationIdentifier() {
        let identifier = SSHBatchModeNotifier.makeNotificationIdentifier(host: "github.com")
        #expect(identifier.hasPrefix("ssh-batch-github.com-"))
        #expect(identifier.count > "ssh-batch-github.com-".count)
    }

    @Test func expiredNonceIsRejected() {
        var store = SSHBatchModeNotifier.NonceStore()
        let nonce = "test-nonce"
        store.register(nonce: nonce, keyFingerprints: ["SHA256:abc"], at: Date().addingTimeInterval(-130))
        #expect(store.validate(nonce: nonce) == nil)
    }

    @Test func validNonceReturnsFingerprints() {
        var store = SSHBatchModeNotifier.NonceStore()
        let nonce = "test-nonce"
        store.register(nonce: nonce, keyFingerprints: ["SHA256:abc", "SHA256:def"], at: Date())
        let result = store.validate(nonce: nonce)
        #expect(result == ["SHA256:abc", "SHA256:def"])
    }

    @Test func nonceIsConsumedOnValidation() {
        var store = SSHBatchModeNotifier.NonceStore()
        let nonce = "test-nonce"
        store.register(nonce: nonce, keyFingerprints: ["SHA256:abc"], at: Date())
        _ = store.validate(nonce: nonce)
        #expect(store.validate(nonce: nonce) == nil)
    }
}
