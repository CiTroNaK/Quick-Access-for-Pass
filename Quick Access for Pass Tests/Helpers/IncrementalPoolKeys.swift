import Foundation
@testable import Quick_Access_for_Pass

/// Simulates device-key creation/lookup using public synthetic bytes only, never Keychain.
actor IncrementalPoolKeys {
    private var present = false
    private var lookups = 0
    private var creations = 0
    func existingSnapshotKey() -> Data? {
        lookups += 1
        return present ? Data(repeating: 7, count: 32) : nil
    }
    func createSnapshotKey() -> Data {
        present = true
        creations += 1
        return Data(repeating: 7, count: 32)
    }
    func counts() -> (lookups: Int, creations: Int) { (lookups, creations) }
}
extension IncrementalPoolKeys: OfflineSnapshotKeyProviding {}
