import Foundation

/// Named pass-cli feature gates derived from the active CLI version.
nonisolated struct PassCLICapabilities: Sendable, Equatable {
    static let minimumShowSecretsVersion = PassCLIVersion(major: 2, minor: 0, patch: 3)
    static let minimumSessionLockingVersion = PassCLIVersion(major: 2, minor: 2, patch: 2)

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

    /// The published full-JSON contract substantiated for this release, not future versions.
    /// Exact build-source correspondence is not established; see the incremental sync evidence.
    var snapshotContentProvenance: CLISnapshotContentProvenance {
        version == PassCLIVersion(major: 2, minor: 4, patch: 2) ? .completeJSONV1 : .unavailable
    }

    /// Whether the active CLI supports managed session locking.
    var supportsSessionLocking: Bool {
        guard let version else { return false }
        return version >= Self.minimumSessionLockingVersion
    }
}
