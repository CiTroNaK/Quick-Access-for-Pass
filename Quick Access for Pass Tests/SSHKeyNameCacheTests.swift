import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("SSHKeyNameCache Tests")
struct SSHKeyNameCacheTests {

    private func makeCache() -> SSHKeyNameCache {
        // Use a fresh instance instead of the shared singleton for test isolation
        SSHKeyNameCache()
    }

    @Test func storeAndRetrieve() {
        let cache = makeCache()
        let blob = Data([0x01, 0x02, 0x03])
        cache.store(keyBlob: blob, comment: "my-key")
        #expect(cache.name(for: blob) == "my-key")
    }

    @Test func unknownKeyReturnsNil() {
        let cache = makeCache()
        let blob = Data([0xFF])
        #expect(cache.name(for: blob) == nil)
    }

    @Test func overwriteExistingKey() {
        let cache = makeCache()
        let blob = Data([0x01, 0x02])
        cache.store(keyBlob: blob, comment: "old-name")
        cache.store(keyBlob: blob, comment: "new-name")
        #expect(cache.name(for: blob) == "new-name")
    }

    @Test func clearRemovesAll() {
        let cache = makeCache()
        let blob1 = Data([0x01])
        let blob2 = Data([0x02])
        cache.store(keyBlob: blob1, comment: "key1")
        cache.store(keyBlob: blob2, comment: "key2")
        cache.clear()
        #expect(cache.name(for: blob1) == nil)
        #expect(cache.name(for: blob2) == nil)
    }

    @Test func differentBlobsAreSeparate() {
        let cache = makeCache()
        let blob1 = Data([0x01])
        let blob2 = Data([0x02])
        cache.store(keyBlob: blob1, comment: "key1")
        cache.store(keyBlob: blob2, comment: "key2")
        #expect(cache.name(for: blob1) == "key1")
        #expect(cache.name(for: blob2) == "key2")
    }
}
