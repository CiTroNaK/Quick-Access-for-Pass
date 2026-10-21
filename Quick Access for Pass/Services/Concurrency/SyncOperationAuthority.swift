import Foundation
import Synchronization

/// Metadata-only whole-sync freshness. This is not authority to release secrets.
nonisolated final class SyncOperationAuthority: Sendable {
    private let current = Mutex<UUID?>(nil)

    func beginOperation() -> SyncOperationToken {
        let id = UUID()
        current.withLock { $0 = id }
        return SyncOperationToken(id: id, authority: self)
    }

    func invalidate() { current.withLock { $0 = nil } }

    fileprivate func isCurrent(_ id: UUID) -> Bool {
        current.withLock { $0 == id }
    }
}

/// Immutable ownership of one sync's metadata and presentation lifetime.
nonisolated struct SyncOperationToken: Sendable {
    let id: UUID
    fileprivate let authority: SyncOperationAuthority

    var isCurrent: Bool { authority.isCurrent(id) }
}
