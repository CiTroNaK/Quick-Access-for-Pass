import Foundation

nonisolated enum OfflineSnapshotLimits {
    static let schemaVersion: UInt8 = 1
    static let plaintextBytes = 4 * 1024 * 1024
    static let ciphertextBytes = plaintextBytes + 28
    static let cliStdoutBytes = plaintextBytes + 4096
    static let cliStderrBytes = 256 * 1024
}

/// Non-secret authenticated identity for an encrypted offline snapshot.
nonisolated struct OfflineSnapshotIdentity: Sendable, Hashable {
    let key: OfflineSnapshotKey
    let revision: UUID
    let keyFingerprint: Data
}

/// Ciphertext and the metadata needed to authenticate its identity.
nonisolated struct EncryptedOfflineSnapshot: Sendable, Equatable {
    let identity: OfflineSnapshotIdentity
    let payload: Data
}

/// Ciphertext with actual-payload source time and certified per-item-type content revision.
nonisolated struct PreparedOfflineSnapshot: Sendable, Equatable {
    let snapshot: EncryptedOfflineSnapshot
    let sourceModifyTime: Date?
    let contentRevision: Int

    init(snapshot: EncryptedOfflineSnapshot, sourceModifyTime: Date?, contentRevision: Int = 0) {
        self.snapshot = snapshot
        self.sourceModifyTime = sourceModifyTime
        self.contentRevision = contentRevision
    }
}
