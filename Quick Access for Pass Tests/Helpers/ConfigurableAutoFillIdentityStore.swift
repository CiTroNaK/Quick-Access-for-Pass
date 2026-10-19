import AuthenticationServices
import Foundation
@testable import Quick_Access_for_Pass

/// In-memory system boundary; never reads or modifies the Mac's real AutoFill store.
actor ConfigurableAutoFillIdentityStore: AutoFillCredentialIdentityStoreAdapting {
    enum Operation: Sendable, CaseIterable {
        case state, readPasswords, readCodes, savePasswords, removePasswords, saveCodes, removeCodes
    }

    private var enabled: Bool
    private var passwords: [AutoFillPasswordIdentity]
    private var codes: [AutoFillOneTimeCodeIdentity]
    private let failureAt: Operation?
    private let failure: NSError
    private let pauseAt: Operation?
    private let pause: OwnershipPause?
    private var calls: [Operation] = []

    init(enabled: Bool = true, passwords: [AutoFillPasswordIdentity] = [], codes: [AutoFillOneTimeCodeIdentity] = [],
         failureAt: Operation? = nil,
         failure: NSError = NSError(domain: ASCredentialIdentityStoreErrorDomain,
                                    code: ASCredentialIdentityStoreError.Code.storeDisabled.rawValue),
         pauseAt: Operation? = nil, pause: OwnershipPause? = nil) {
        self.enabled = enabled
        self.passwords = passwords
        self.codes = codes
        self.failureAt = failureAt
        self.failure = failure
        self.pauseAt = pauseAt
        self.pause = pause
    }

    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func operations() -> [Operation] { calls }

    func isEnabled() async -> Bool {
        calls.append(.state)
        if pauseAt == .state { await pause?.suspend() }
        return enabled
    }

    private func enter(_ operation: Operation) async throws {
        calls.append(operation)
        if pauseAt == operation { await pause?.suspend() }
        if failureAt == operation { throw failure }
    }

    func passwordIdentities() async throws -> [AutoFillPasswordIdentity] {
        try await enter(.readPasswords)
        return passwords
    }

    func oneTimeCodeIdentities() async throws -> [AutoFillOneTimeCodeIdentity] {
        try await enter(.readCodes)
        return codes
    }

    func savePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws {
        try await enter(.savePasswords)
        let ids = Set(identities.map(\.descriptorID))
        passwords.removeAll { ids.contains($0.descriptorID) }
        passwords.append(contentsOf: identities)
    }

    func removePasswordIdentities(_ identities: [AutoFillPasswordIdentity]) async throws {
        try await enter(.removePasswords)
        let ids = Set(identities.map(\.descriptorID))
        passwords.removeAll { ids.contains($0.descriptorID) }
    }

    func saveOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws {
        try await enter(.saveCodes)
        let ids = Set(identities.map(\.descriptorID))
        codes.removeAll { ids.contains($0.descriptorID) }
        codes.append(contentsOf: identities)
    }

    func removeOneTimeCodeIdentities(_ identities: [AutoFillOneTimeCodeIdentity]) async throws {
        try await enter(.removeCodes)
        let ids = Set(identities.map(\.descriptorID))
        codes.removeAll { ids.contains($0.descriptorID) }
    }
}
