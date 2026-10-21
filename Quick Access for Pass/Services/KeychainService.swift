import Foundation
import Security

nonisolated enum KeychainPassphraseQueryKind: Sendable, CaseIterable {
    case retrieve
    case add
    case update
    case delete
}

nonisolated struct KeychainService: Sendable {
    static let defaultServiceName = "codes.petr.quick-access-for-pass"
    private static let databasePassphraseAccount = "database-passphrase"

    let serviceName: String
    let accessGroup: String
    private let backend: Backend

    init(
        serviceName: String = KeychainService.defaultServiceName,
        accessGroup: String = AutoFillConstants.keychainAccessGroup,
        backend: Backend = .system
    ) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
        self.backend = backend
    }

    func retrievePassphrase() throws -> Data? {
        try retrieve(accessGroup: accessGroup)
    }

    /// Diagnostic-only lookup matching the historical implicit-group query.
    /// Callers must never use its result to copy, update, or rekey an existing item.
    func retrieveLegacyPassphrase() throws -> Data? {
        try retrieve(accessGroup: nil)
    }

    func getOrCreatePassphrase() throws -> Data {
        if let existing = try retrievePassphrase() {
            return existing
        }
        let passphrase = try generatePassphrase()
        try storeData(passphrase)
        return passphrase
    }

    func deletePassphrase() throws {
        let query = PassphraseQuery(
            kind: .delete,
            serviceName: serviceName,
            accessGroup: accessGroup
        )
        switch backend.delete(query) {
        case .success:
            return
        case .failure(.deleteFailed(errSecItemNotFound)):
            return
        case .failure(let error):
            throw error
        }
    }

    func store(_ passphrase: String) throws {
        guard let data = passphrase.data(using: .utf8) else {
            throw KeychainError.storeFailed(errSecParam)
        }
        try storeData(data)
    }

    private func retrieve(accessGroup: String?) throws -> Data? {
        let query = PassphraseQuery(
            kind: .retrieve,
            serviceName: serviceName,
            accessGroup: accessGroup
        )
        return try backend.retrieve(query).get()
    }

    private func storeData(_ passphrase: Data) throws {
        let addQuery = PassphraseQuery(
            kind: .add,
            serviceName: serviceName,
            accessGroup: accessGroup,
            value: passphrase
        )
        switch backend.add(addQuery) {
        case .success:
            return
        case .failure(.storeFailed(errSecDuplicateItem)):
            let updateQuery = PassphraseQuery(
                kind: .update,
                serviceName: serviceName,
                accessGroup: accessGroup,
                value: passphrase
            )
            try backend.update(updateQuery).get()
        case .failure(let error):
            throw error
        }
    }

    private func generatePassphrase() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.randomGenerationFailed(status)
        }
        return Data(bytes.map { String(format: "%02x", $0) }.joined().utf8)
    }

    nonisolated struct PassphraseQuery: Sendable {
        let kind: KeychainPassphraseQueryKind
        let serviceName: String
        let accessGroup: String?
        let value: Data?

        init(kind: KeychainPassphraseQueryKind, serviceName: String, accessGroup: String?, value: Data? = nil) {
            self.kind = kind
            self.serviceName = serviceName
            self.accessGroup = accessGroup
            self.value = value
        }

        var searchDictionary: [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: KeychainService.databasePassphraseAccount,
                kSecUseDataProtectionKeychain as String: true,
            ]
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            switch kind {
            case .retrieve:
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
            case .add:
                query[kSecValueData as String] = value
                query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .update, .delete:
                break
            }
            return query
        }

        var updateDictionary: [String: Any] {
            guard kind == .update, let value else { return [:] }
            return [kSecValueData as String: value]
        }
    }

    nonisolated struct Backend: Sendable {
        let retrieve: @Sendable (PassphraseQuery) -> Result<Data?, KeychainError>
        let add: @Sendable (PassphraseQuery) -> Result<Void, KeychainError>
        let update: @Sendable (PassphraseQuery) -> Result<Void, KeychainError>
        let delete: @Sendable (PassphraseQuery) -> Result<Void, KeychainError>

        static let system = Backend(
            retrieve: { query in
                var result: AnyObject?
                let status = SecItemCopyMatching(query.searchDictionary as CFDictionary, &result)
                switch status {
                case errSecSuccess:
                    guard let data = result as? Data else {
                        return .failure(.retrieveFailed(errSecDecode))
                    }
                    return .success(data)
                case errSecItemNotFound:
                    return .success(nil)
                default:
                    return .failure(.retrieveFailed(status))
                }
            },
            add: { query in
                let status = SecItemAdd(query.searchDictionary as CFDictionary, nil)
                return status == errSecSuccess ? .success(()) : .failure(.storeFailed(status))
            },
            update: { query in
                let status = SecItemUpdate(
                    query.searchDictionary as CFDictionary,
                    query.updateDictionary as CFDictionary
                )
                return status == errSecSuccess ? .success(()) : .failure(.storeFailed(status))
            },
            delete: { query in
                let status = SecItemDelete(query.searchDictionary as CFDictionary)
                return status == errSecSuccess ? .success(()) : .failure(.deleteFailed(status))
            }
        )
    }
}

nonisolated enum KeychainError: Error, LocalizedError, Sendable {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        // OSStatus results
        // swiftlint:disable identifier_name
        switch self {
        case .storeFailed(let s): String(localized: "Keychain store failed: \(s)")
        case .retrieveFailed(let s): String(localized: "Keychain retrieve failed: \(s)")
        case .deleteFailed(let s): String(localized: "Keychain delete failed: \(s)")
        case .randomGenerationFailed(let s): String(localized: "Secure random generation failed: \(s)")
        }
        // swiftlint:enable identifier_name
    }
}
