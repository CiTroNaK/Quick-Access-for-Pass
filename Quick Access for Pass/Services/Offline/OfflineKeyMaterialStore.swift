import Foundation
import Security

/// Focused capability for operations that need the independent snapshot key.
nonisolated protocol OfflineSnapshotKeyProviding: Sendable {
    func existingSnapshotKey() async throws -> Data?
    func createSnapshotKey() async throws -> Data
}

actor OfflineKeyMaterialStore: OfflineSnapshotKeyProviding {
    enum Error: Swift.Error, Equatable, Sendable {
        case itemNotFound
        case interactionNotAllowed
        case invalidMaterial
        case securityStatus(OSStatus)
        case randomGenerationFailed(OSStatus)
    }

    nonisolated enum QueryKind: Sendable {
        case retrieve
        case add
    }

    /// Sendable Keychain input. CF dictionaries are assembled only by the live backend.
    nonisolated struct Query: Sendable {
        let kind: QueryKind
        let service: String
        let account: String
        let hostAccessGroup: String
        let data: Data?

        init(kind: QueryKind, service: String, account: String, hostAccessGroup: String, data: Data? = nil) {
            self.kind = kind
            self.service = service
            self.account = account
            self.hostAccessGroup = hostAccessGroup
            self.data = data
        }

        var keychainDictionary: [String: Any] {
            var dictionary: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrAccessGroup as String: hostAccessGroup,
            ]
            if kind == .retrieve {
                dictionary[kSecReturnData as String] = true
                dictionary[kSecMatchLimit as String] = kSecMatchLimitOne
            }
            if kind == .add, let data {
                dictionary[kSecValueData as String] = data
                dictionary[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
            return dictionary
        }
    }

    nonisolated enum Retrieval: Sendable {
        case success(Data)
        case invalidMaterial
        case failure(OSStatus)
    }

    nonisolated struct Backend: Sendable {
        let retrieve: @Sendable (Query) -> Retrieval
        let add: @Sendable (Query) -> OSStatus

        static let live = Self(
            retrieve: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query.keychainDictionary as CFDictionary, &result)
                guard status == errSecSuccess else { return .failure(status) }
                guard let data = result as? Data else { return .invalidMaterial }
                return .success(data)
            },
            add: { query in SecItemAdd(query.keychainDictionary as CFDictionary, nil) }
        )
    }

    nonisolated private static let snapshotKeyAccount = "offline-snapshot-key"

    private let serviceName: String
    private let hostAccessGroup: String
    private let backend: Backend

    init(
        serviceName: String = "codes.petr.quick-access-for-pass.offline",
        hostAccessGroup: String = AutoFillConstants.keychainAccessGroup,
        backend: Backend = .live
    ) {
        self.serviceName = serviceName
        self.hostAccessGroup = hostAccessGroup
        self.backend = backend
    }

    func existingSnapshotKey() throws -> Data? {
        try retrieveValidatedExistingKey()
    }

    func createSnapshotKey() throws -> Data {
        if let existing = try retrieveValidatedExistingKey() {
            return existing
        }
        let generated = try randomMaterial()
        let status = backend.add(query(kind: .add, data: generated))
        switch status {
        case errSecSuccess:
            return generated
        case errSecDuplicateItem:
            guard let winner = try retrieveValidatedExistingKey() else { throw Error.itemNotFound }
            return winner
        case errSecInteractionNotAllowed:
            throw Error.interactionNotAllowed
        default:
            throw Error.securityStatus(status)
        }
    }

    private func retrieveValidatedExistingKey() throws -> Data? {
        switch backend.retrieve(query(kind: .retrieve)) {
        case let .success(data):
            guard data.count == 32 else { throw Error.invalidMaterial }
            return data
        case .invalidMaterial:
            throw Error.invalidMaterial
        case let .failure(status) where status == errSecItemNotFound:
            return nil
        case let .failure(status) where status == errSecInteractionNotAllowed:
            throw Error.interactionNotAllowed
        case let .failure(status):
            throw Error.securityStatus(status)
        }
    }

    private func query(kind: QueryKind, data: Data? = nil) -> Query {
        Query(
            kind: kind,
            service: serviceName,
            account: Self.snapshotKeyAccount,
            hostAccessGroup: hostAccessGroup,
            data: data
        )
    }

    private func randomMaterial() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Error.randomGenerationFailed(status) }
        return Data(bytes)
    }
}
