import Darwin
import Foundation
import Security

nonisolated struct VerifiedAutoFillPeer: Equatable, Sendable {
    let fileDescriptor: Int32
    let identifier: String
    let teamID: String
}

nonisolated enum AutoFillPeerVerificationError: Error, Equatable, Sendable {
    case invalidExpectedIdentity
    case peerTokenUnavailable
    case invalidAuditToken
    case guestLookupFailed(OSStatus)
    case requirementCreationFailed(OSStatus)
    case invalidPeer
}

/// Dedicated verifier for the AutoFill boundary. It deliberately does not use
/// the Run/SSH `PeerVerifier`, because this protocol requires certificate-team
/// and exact-identifier pinning without entitlement or PID fallbacks.
nonisolated struct AutoFillPeerVerifier: Sendable {
    typealias PeerTokenLookup = @Sendable (Int32) throws -> Data
    typealias SecurityValidation = @Sendable (Data, String) throws -> Void

    private let peerTokenLookup: PeerTokenLookup
    private let securityValidation: SecurityValidation

    init(
        peerTokenLookup: @escaping PeerTokenLookup = Self.localPeerToken,
        securityValidation: @escaping SecurityValidation = Self.validateSecurityGuest
    ) {
        self.peerTokenLookup = peerTokenLookup
        self.securityValidation = securityValidation
    }

    static func verify(
        fd: Int32,
        expectedIdentifier: String,
        teamID: String
    ) throws -> VerifiedAutoFillPeer {
        try AutoFillPeerVerifier().verify(
            fd: fd,
            expectedIdentifier: expectedIdentifier,
            teamID: teamID
        )
    }

    func verify(
        fd: Int32,
        expectedIdentifier: String,
        teamID: String
    ) throws -> VerifiedAutoFillPeer {
        let requirement = try Self.requirementString(
            identifier: expectedIdentifier,
            teamID: teamID
        )
        let auditToken = try peerTokenLookup(fd)
        guard auditToken.count == MemoryLayout<audit_token_t>.size else {
            throw AutoFillPeerVerificationError.invalidAuditToken
        }
        try securityValidation(auditToken, requirement)
        return VerifiedAutoFillPeer(
            fileDescriptor: fd,
            identifier: expectedIdentifier,
            teamID: teamID
        )
    }

    static func requirementString(identifier: String, teamID: String) throws -> String {
        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let teamCharacters = CharacterSet.alphanumerics
        guard identifier.isEmpty == false,
              teamID.isEmpty == false,
              identifier.unicodeScalars.allSatisfy(identifierCharacters.contains),
              teamID.unicodeScalars.allSatisfy(teamCharacters.contains) else {
            throw AutoFillPeerVerificationError.invalidExpectedIdentity
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    private static func localPeerToken(fd: Int32) throws -> Data {
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &tokenSize)
        }
        guard status == 0, tokenSize == MemoryLayout<audit_token_t>.size else {
            throw AutoFillPeerVerificationError.peerTokenUnavailable
        }
        return withUnsafeBytes(of: token) { Data($0) }
    }

    private static func validateSecurityGuest(
        auditToken: Data,
        requirementString: String
    ) throws {
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            throw AutoFillPeerVerificationError.guestLookupFailed(guestStatus)
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementString as CFString,
            [],
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw AutoFillPeerVerificationError.requirementCreationFailed(requirementStatus)
        }

        guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw AutoFillPeerVerificationError.invalidPeer
        }
    }
}
