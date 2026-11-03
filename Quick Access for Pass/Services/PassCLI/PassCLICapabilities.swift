import Foundation

/// Named pass-cli feature gates derived from the active CLI version.
nonisolated struct PassCLICapabilities: Sendable, Equatable {
    static let minimumShowSecretsVersion = PassCLIVersion(major: 2, minor: 0, patch: 3)
    static let minimumSessionLockingVersion = PassCLIVersion(major: 2, minor: 2, patch: 2)
    static let minimumFoldersVersion = PassCLIVersion(major: 2, minor: 5, patch: 0)
    /// Newer releases may reuse list content only after an in-sync `item view` agreement check.
    static let minimumUnverifiedContentReuseVersion = PassCLIVersion(major: 2, minor: 5, patch: 0)
    /// Kill switch for a release known to return well-formed but wrong list content.
    static let blockedContentReuseVersions: [PassCLIVersion] = []

    /// The parsed active CLI version, or `nil` when version output is unavailable or invalid.
    let version: PassCLIVersion?

    /// Creates capabilities for an already parsed CLI version.
    init(version: PassCLIVersion?) {
        self.version = version
    }

    /// Creates capabilities by parsing raw `pass-cli --version` output.
    init(rawVersionString: String?) {
        self.version = PassCLIVersion(rawVersionString)
    }

    /// Whether the active CLI supports including secrets in item-list output.
    var supportsShowSecrets: Bool {
        guard let version else { return false }
        return version >= Self.minimumShowSecretsVersion
    }

    /// Published full-JSON contracts substantiated for exact releases. Other 2.5.0+ releases are
    /// unverified and need per-sync agreement evidence; see the incremental sync evidence.
    var snapshotContentProvenance: CLISnapshotContentProvenance {
        guard let version, !Self.blockedContentReuseVersions.contains(version) else { return .unavailable }
        switch version {
        case PassCLIVersion(major: 2, minor: 1, patch: 4),
             PassCLIVersion(major: 2, minor: 2, patch: 3),
             PassCLIVersion(major: 2, minor: 3, patch: 3),
             PassCLIVersion(major: 2, minor: 4, patch: 2),
             PassCLIVersion(major: 2, minor: 5, patch: 1),
             PassCLIVersion(major: 2, minor: 7, patch: 0):
            return .completeJSONV1
        default:
            return version >= Self.minimumUnverifiedContentReuseVersion ? .unverifiedCompleteJSON : .unavailable
        }
    }

    /// Whether the active CLI supports folder metadata commands.
    var supportsFolders: Bool {
        guard let version else { return false }
        return version >= Self.minimumFoldersVersion
    }

    /// Whether the active CLI supports managed session locking.
    var supportsSessionLocking: Bool {
        guard let version else { return false }
        return version >= Self.minimumSessionLockingVersion
    }
}
