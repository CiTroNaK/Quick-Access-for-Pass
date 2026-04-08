import Foundation
import Security
import Darwin
import os

// MARK: - Types

nonisolated enum PeerIdentity: Sendable, Equatable {
    case signedApp(bundleID: String, teamID: String)
    case trustedHelper
    case unverified(pid: pid_t)

    var appIdentifier: String? {
        switch self {
        case .signedApp(let bundleID, let teamID):
            return "\(teamID).\(bundleID)"
        case .trustedHelper:
            return nil
        case .unverified(let pid):
            return "unverified.\(pid)"
        }
    }

    var teamID: String? {
        if case .signedApp(_, let teamID) = self {
            return teamID
        }
        return nil
    }
}

nonisolated struct VerifiedConnection: Sendable {
    let fd: Int32
    let identity: PeerIdentity
    let pid: pid_t
}

// MARK: - Verifier

nonisolated enum PeerVerifier {
    nonisolated struct SignedIdentity: Equatable, Sendable {
        let identifier: String
        let teamID: String
    }

    static func verify(fd: Int32) -> VerifiedConnection {
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0 else {
            AppLogger.sshProxy.warning("PeerVerifier: failed to get audit token from fd \(fd, privacy: .public)")
            return VerifiedConnection(fd: fd, identity: .unverified(pid: 0), pid: 0)
        }

        let pid = extractPID(from: token)
        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var peerCode: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &peerCode)
        guard guestStatus == errSecSuccess, let peerCode else {
            AppLogger.sshProxy.info("PeerVerifier: SecCodeCopyGuestWithAttributes failed for pid \(pid, privacy: .public): \(guestStatus, privacy: .public)")
            return VerifiedConnection(fd: fd, identity: .unverified(pid: pid), pid: pid)
        }

        var peerStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(peerCode, [], &peerStaticCode) == errSecSuccess,
              let peerStaticCode else {
            return VerifiedConnection(fd: fd, identity: .unverified(pid: pid), pid: pid)
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            return VerifiedConnection(fd: fd, identity: .unverified(pid: pid), pid: pid)
        }

        let validityStatus = SecStaticCodeCheckValidity(peerStaticCode, [], requirement)
        guard validityStatus == errSecSuccess else {
            AppLogger.sshProxy.info("PeerVerifier: peer pid \(pid, privacy: .public) is not Apple-anchored signed")
            return VerifiedConnection(fd: fd, identity: .unverified(pid: pid), pid: pid)
        }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(peerStaticCode, [], &info)
        guard infoStatus == errSecSuccess,
              let signingInfo = info as? [String: Any],
              let signedIdentity = resolveSigningIdentity(from: signingInfo) else {
            AppLogger.sshProxy.info("PeerVerifier: peer pid \(pid, privacy: .public) signed but missing bundle/team ID")
            return VerifiedConnection(fd: fd, identity: .unverified(pid: pid), pid: pid)
        }

        if isTrustedHelper(identifier: signedIdentity.identifier, teamID: signedIdentity.teamID, selfTeamID: selfTeamID()) {
            return VerifiedConnection(fd: fd, identity: .trustedHelper, pid: pid)
        }

        return VerifiedConnection(fd: fd, identity: .signedApp(bundleID: signedIdentity.identifier, teamID: signedIdentity.teamID), pid: pid)
    }

    private static func extractPID(from token: audit_token_t) -> pid_t {
        withUnsafeBytes(of: token) { rawBuffer in
            let values = rawBuffer.bindMemory(to: UInt32.self)
            guard values.count >= 6 else { return 0 }
            return pid_t(values[5])
        }
    }

    static func resolveSigningIdentity(from signingInfo: [String: Any]) -> SignedIdentity? {
        let identifier = (signingInfo[kSecCodeInfoIdentifier as String] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let identifier, !identifier.isEmpty else { return nil }

        let entitlements = signingInfo[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let explicitTeamID = entitlements?["com.apple.developer.team-identifier"] as? String
        let applicationIdentifier = entitlements?["com.apple.application-identifier"] as? String
        let applicationIdentifierPrefix = applicationIdentifier?
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init)
        let directTeamID = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
        guard let teamID = directTeamID ?? explicitTeamID ?? applicationIdentifierPrefix,
              !teamID.isEmpty else {
            return nil
        }

        return SignedIdentity(identifier: identifier, teamID: teamID)
    }

    static func isTrustedHelper(identifier: String, teamID: String?, selfTeamID: String?) -> Bool {
        guard identifier == "qa-run" else { return false }
        guard let teamID, let selfTeamID else { return false }
        return teamID == selfTeamID
    }

    private static func selfTeamID() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            return nil
        }

        var selfStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStaticCode) == errSecSuccess,
              let selfStaticCode else {
            return nil
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(selfStaticCode, [], &info) == errSecSuccess,
              let signingInfo = info as? [String: Any] else {
            return nil
        }

        return resolveSigningIdentity(from: signingInfo)?.teamID
    }
}
