import AuthenticationServices
import Foundation

/// Non-secret password identity metadata exchanged with the system-store adapter.
nonisolated struct AutoFillPasswordIdentity: Sendable, Hashable {
    let descriptorID: UUID
    let serviceIdentifier: String
    let username: String

    init(descriptorID: UUID, serviceIdentifier: String, username: String) {
        self.descriptorID = descriptorID
        self.serviceIdentifier = serviceIdentifier
        self.username = username
    }

    init(descriptor: AutoFillCredentialDescriptor) {
        self.init(
            descriptorID: descriptor.id,
            serviceIdentifier: descriptor.serviceIdentifier,
            username: descriptor.username
        )
    }
}

/// Non-secret one-time-code identity metadata exchanged with the system-store adapter.
nonisolated struct AutoFillOneTimeCodeIdentity: Sendable, Hashable {
    let descriptorID: UUID
    let serviceIdentifier: String
    let label: String

    init(descriptorID: UUID, serviceIdentifier: String, label: String) {
        self.descriptorID = descriptorID
        self.serviceIdentifier = serviceIdentifier
        self.label = label
    }

    init(descriptor: AutoFillCredentialDescriptor) {
        self.init(
            descriptorID: descriptor.id,
            serviceIdentifier: descriptor.serviceIdentifier,
            label: descriptor.title
        )
    }
}

/// Testable boundary around password and one-time-code identity-store operations.
nonisolated protocol AutoFillCredentialIdentityStoreAdapting: Sendable {
    func passwordIdentities() async throws -> [AutoFillPasswordIdentity]
    func oneTimeCodeIdentities() async throws -> [AutoFillOneTimeCodeIdentity]
    func savePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws
    func removePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws
    func saveOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws
    func removeOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws
}

/// Reconciles persisted descriptors with the two supported system identity types.
nonisolated protocol AutoFillIdentitySynchronizing: Sendable {
    func reconcile(descriptors: [AutoFillCredentialDescriptor]) async throws
}

/// Actor that independently reconciles password and one-time-code identities.
actor AutoFillIdentitySynchronizer: AutoFillIdentitySynchronizing {
    private let adapter: any AutoFillCredentialIdentityStoreAdapting

    init(adapter: any AutoFillCredentialIdentityStoreAdapting) {
        self.adapter = adapter
    }

    func reconcile(descriptors: [AutoFillCredentialDescriptor]) async throws {
        let desiredPasswords = descriptors.map(AutoFillPasswordIdentity.init(descriptor:))
        let desiredOneTimeCodes = descriptors
            .filter(\.hasTOTP)
            .map(AutoFillOneTimeCodeIdentity.init(descriptor:))
        let currentPasswords = try await adapter.passwordIdentities()
        let currentOneTimeCodes = try await adapter.oneTimeCodeIdentities()

        let passwordChanges = changes(current: currentPasswords, desired: desiredPasswords, id: \.descriptorID)
        let oneTimeCodeChanges = changes(
            current: currentOneTimeCodes,
            desired: desiredOneTimeCodes,
            id: \.descriptorID
        )

        if !passwordChanges.toSave.isEmpty {
            try await adapter.savePasswordIdentities(passwordChanges.toSave)
        }
        if !passwordChanges.toRemove.isEmpty {
            try await adapter.removePasswordIdentities(passwordChanges.toRemove)
        }
        if !oneTimeCodeChanges.toSave.isEmpty {
            try await adapter.saveOneTimeCodeIdentities(oneTimeCodeChanges.toSave)
        }
        if !oneTimeCodeChanges.toRemove.isEmpty {
            try await adapter.removeOneTimeCodeIdentities(oneTimeCodeChanges.toRemove)
        }
    }

    private func changes<Identity: Hashable & Sendable>(
        current: [Identity],
        desired: [Identity],
        id: KeyPath<Identity, UUID>
    ) -> (toSave: [Identity], toRemove: [Identity]) {
        var currentByID: [UUID: Identity] = [:]
        for identity in current {
            currentByID[identity[keyPath: id]] = identity
        }
        var desiredByID: [UUID: Identity] = [:]
        for identity in desired {
            desiredByID[identity[keyPath: id]] = identity
        }
        let toSave = desired.filter { currentByID[$0[keyPath: id]] != $0 }
        let toRemove = current.filter { desiredByID[$0[keyPath: id]] == nil }
        return (toSave, toRemove)
    }
}

/// Production adapter for the system credential identity store.
actor ASCredentialIdentityStoreAdapter: AutoFillCredentialIdentityStoreAdapting {
    func passwordIdentities() async throws -> [AutoFillPasswordIdentity] {
        let identities = await ASCredentialIdentityStore.shared.credentialIdentities(
            credentialIdentityTypes: .password
        )
        return identities.compactMap { identity in
            guard let password = identity as? ASPasswordCredentialIdentity,
                  let identifier = password.recordIdentifier,
                  let descriptorID = UUID(uuidString: identifier) else {
                return nil
            }
            return AutoFillPasswordIdentity(
                descriptorID: descriptorID,
                serviceIdentifier: password.serviceIdentifier.identifier,
                username: password.user
            )
        }
    }

    func oneTimeCodeIdentities() async throws -> [AutoFillOneTimeCodeIdentity] {
        let identities = await ASCredentialIdentityStore.shared.credentialIdentities(
            credentialIdentityTypes: .oneTimeCode
        )
        return identities.compactMap { identity in
            guard let oneTimeCode = identity as? ASOneTimeCodeCredentialIdentity,
                  let identifier = oneTimeCode.recordIdentifier,
                  let descriptorID = UUID(uuidString: identifier) else {
                return nil
            }
            return AutoFillOneTimeCodeIdentity(
                descriptorID: descriptorID,
                serviceIdentifier: oneTimeCode.serviceIdentifier.identifier,
                label: oneTimeCode.label
            )
        }
    }

    func savePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws {
        let systemIdentities: [any ASCredentialIdentity] = identities.map(Self.makePasswordIdentity)
        try await ASCredentialIdentityStore.shared.saveCredentialIdentities(systemIdentities)
    }

    func removePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws {
        let systemIdentities: [any ASCredentialIdentity] = identities.map(Self.makePasswordIdentity)
        try await ASCredentialIdentityStore.shared.removeCredentialIdentities(systemIdentities)
    }

    func saveOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws {
        let systemIdentities: [any ASCredentialIdentity] = identities.map(Self.makeOneTimeCodeIdentity)
        try await ASCredentialIdentityStore.shared.saveCredentialIdentities(systemIdentities)
    }

    func removeOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws {
        let systemIdentities: [any ASCredentialIdentity] = identities.map(Self.makeOneTimeCodeIdentity)
        try await ASCredentialIdentityStore.shared.removeCredentialIdentities(systemIdentities)
    }

    private static func makePasswordIdentity(_ identity: AutoFillPasswordIdentity) -> ASPasswordCredentialIdentity {
        ASPasswordCredentialIdentity(
            serviceIdentifier: ASCredentialServiceIdentifier(
                identifier: identity.serviceIdentifier,
                type: .domain
            ),
            user: identity.username,
            recordIdentifier: identity.descriptorID.uuidString
        )
    }

    private static func makeOneTimeCodeIdentity(
        _ identity: AutoFillOneTimeCodeIdentity
    ) -> ASOneTimeCodeCredentialIdentity {
        ASOneTimeCodeCredentialIdentity(
            serviceIdentifier: ASCredentialServiceIdentifier(
                identifier: identity.serviceIdentifier,
                type: .domain
            ),
            label: identity.label,
            recordIdentifier: identity.descriptorID.uuidString
        )
    }
}

/// Default used by isolated coordinator tests that do not exercise successful sync.
nonisolated struct DisabledAutoFillIdentitySynchronizer: AutoFillIdentitySynchronizing {
    func reconcile(descriptors: [AutoFillCredentialDescriptor]) async throws {}
}
