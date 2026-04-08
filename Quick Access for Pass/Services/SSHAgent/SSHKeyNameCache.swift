import Foundation

/// Caches key blob -> comment mappings learned from SSH agent IDENTITIES_ANSWER responses.
/// Uses NSLock instead of actor because `store` is called from a blocking GCD thread
/// in SSHAgentProxy.runClientLoop where `await` is not available.
nonisolated final class SSHKeyNameCache: @unchecked Sendable {
    static let shared = SSHKeyNameCache()
    private var names: [Data: String] = [:]
    private let lock = NSLock()

    func store(keyBlob: Data, comment: String) {
        lock.withLock { names[keyBlob] = comment }
    }

    func name(for keyBlob: Data) -> String? {
        lock.withLock { names[keyBlob] }
    }

    func clear() {
        lock.withLock { names.removeAll() }
    }
}
