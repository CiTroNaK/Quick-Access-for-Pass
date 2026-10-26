import Foundation
import Synchronization
@testable import Quick_Access_for_Pass

/// Controlled CLI boundary for native rendering/lifecycle tests. Locking keeps call inspection
/// synchronous; the real coordinator, service, repository, and operation ownership are not mocked.
nonisolated final class OfflineFolderManagerViewer: OfflineItemViewing {
    private let calls = Mutex<[String: Int]>([:])
    private let beforeView: @Sendable () async throws -> Void

    init(beforeView: @escaping @Sendable () async throws -> Void) {
        self.beforeView = beforeView
    }

    func callCount(itemID: String) -> Int { calls.withLock { $0[itemID, default: 0] } }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        calls.withLock { $0[itemId, default: 0] += 1 }
        try await beforeView()
        return try offlineTestCLIItem(id: itemId, vaultID: "vault", shareID: shareId, password: "synthetic")
    }
}
