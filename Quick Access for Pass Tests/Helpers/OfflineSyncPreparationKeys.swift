import Foundation
@testable import Quick_Access_for_Pass

/// A cancellable synthetic key lookup, never a real Keychain dependency.
actor OfflineSyncPreparationKeys {
    let gate: OfflineTestGate

    init(gate: OfflineTestGate) { self.gate = gate }

    func existingSnapshotKey() async throws -> Data? {
        try await gate.wait()
        return Data(repeating: 7, count: 32)
    }

    func createSnapshotKey() -> Data { Data(repeating: 7, count: 32) }
}

extension OfflineSyncPreparationKeys: OfflineSnapshotKeyProviding {}
