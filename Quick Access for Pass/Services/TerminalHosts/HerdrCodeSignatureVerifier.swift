import AppKit
import Darwin
import Foundation
import os
import Security

/// Recognizes Herdr Core processes and the installed Herdr.app by code signature. Display context only:
/// a verdict never grants authorization and is never persisted.
nonisolated protocol HerdrCodeSignatureVerifying: Sendable {
    func isVerifiedCore(pid: pid_t) -> Bool
    func isVerifiedCore(auditToken: audit_token_t) -> Bool
    /// Installed Herdr.app whose static signature satisfies the app requirement, or nil.
    func verifiedHerdrAppURL() -> URL?
}

nonisolated final class LiveHerdrCodeSignatureVerifier: HerdrCodeSignatureVerifying, @unchecked Sendable {
    /// Developer ID leaf from the Herdr team; shared by both requirements.
    private static let developerIDTeam = #" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
        + #" and certificate leaf[subject.OU] = "2W9652Q7QR""#
    static let coreRequirement = #"identifier "dev.herdr.core""# + developerIDTeam
    static let appRequirement = #"identifier "dev.herdr.app""# + developerIDTeam

    private struct AppFileIdentity: Equatable {
        let path: String
        let inode: UInt64
        let modified: timespec

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.path == rhs.path && lhs.inode == rhs.inode
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }
    }

    private struct AppVerdict {
        let identity: AppFileIdentity
        let isValid: Bool
    }

    /// Compiled once; immutable CF objects that are safe to share across threads. nil (invalid text) fails closed.
    private let coreRequirement: SecRequirement?
    private let appRequirement: SecRequirement?
    private let locateApp: @Sendable () -> URL?
    // Guards the icon-only app verdict cache and the test-visible validation counter; justifies @unchecked Sendable.
    private let state = OSAllocatedUnfairLock<(verdict: AppVerdict?, validations: Int)>(initialState: (nil, 0))
    /// Peer verdicts keyed by the complete audit token. The token includes the pid version, which changes on exit
    /// and on exec, so a verdict never outlives the exact process image it was computed for.
    private let peerVerdicts = OSAllocatedUnfairLock<(verdicts: [Data: Bool], validations: Int)>(initialState: ([:], 0))
    private static let maximumPeerVerdicts = 32

    init(coreRequirement: String = coreRequirement, appRequirement: String = appRequirement,
         locateApp: @escaping @Sendable () -> URL? = {
             NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.herdr.app")
         }) {
        self.coreRequirement = Self.requirement(coreRequirement)
        self.appRequirement = Self.requirement(appRequirement)
        self.locateApp = locateApp
    }

    /// Running-code validation. `kSecCSDoNotValidateResources` is rejected here (errSecCSInvalidFlags); it applies only to
    /// static checks, so repeated peer checks are made cheap by the audit-token cache instead.
    static let dynamicValidityFlags = SecCSFlags(rawValue: kSecCSStrictValidate)

    var validationCount: Int { state.withLock { $0.validations } }
    var peerValidationCount: Int { peerVerdicts.withLock { $0.validations } }

    func isVerifiedCore(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        return isVerifiedGuest([kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary)
    }

    func isVerifiedCore(auditToken: audit_token_t) -> Bool {
        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        if let cached = peerVerdicts.withLock({ $0.verdicts[tokenData] }) { return cached }
        let isValid = isVerifiedGuest([kSecGuestAttributeAudit: tokenData] as CFDictionary)
        peerVerdicts.withLock { state in
            if state.verdicts.count >= Self.maximumPeerVerdicts { state.verdicts.removeAll() }
            state.verdicts[tokenData] = isValid
            state.validations += 1
        }
        return isValid
    }

    func verifiedHerdrAppURL() -> URL? {
        guard let url = locateApp()?.standardizedFileURL, let identity = Self.fileIdentity(url.path) else { return nil }
        if let cached = state.withLock({ $0.verdict }), cached.identity == identity {
            return cached.isValid ? url : nil
        }
        // The icon is not an authority, so bundle resources are not validated (it is also the slow part).
        let isValid = Self.isValidApp(at: url, requirement: appRequirement)
        state.withLock { $0 = (AppVerdict(identity: identity, isValid: isValid), $0.validations + 1) }
        return isValid ? url : nil
    }

    private func isVerifiedGuest(_ attributes: CFDictionary) -> Bool {
        var code: SecCode?
        guard let requirement = coreRequirement,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, Self.dynamicValidityFlags, requirement) == errSecSuccess
    }

    private static func isValidApp(at url: URL, requirement: SecRequirement?) -> Bool {
        var code: SecStaticCode?
        guard let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func fileIdentity(_ path: String) -> AppFileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return .init(path: path, inode: UInt64(info.st_ino), modified: info.st_mtimespec)
    }
}
