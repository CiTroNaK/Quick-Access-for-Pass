import Foundation

/// User-facing Pass CLI features summarized in Settings. Display only; never authorization.
nonisolated enum PassCLIFeature: CaseIterable, Sendable, Equatable {
    case folders
    case fastOfflineSync
    case vaultPasswordPolicy
}

nonisolated enum PassCLIFeatureStatus: Sendable, Equatable {
    /// The version meets the minimum and is a tested release.
    case supported
    /// The version meets the minimum but this release was not tested.
    case untested
    /// The version is below the minimum, or the feature is disabled for this release.
    case unsupported(minimumVersion: PassCLIVersion?)
}

nonisolated struct PassCLIFeatureSupport: Sendable, Equatable, Identifiable {
    let feature: PassCLIFeature
    let status: PassCLIFeatureStatus

    var id: PassCLIFeature { feature }
}

nonisolated extension PassCLICapabilities {
    /// The first release where a vault owner can hide sensitive content from the CLI.
    static let minimumSensitiveContentPolicyVersion = PassCLIVersion(major: 2, minor: 7, patch: 0)

    /// Feature rows for the active CLI, or empty when its version is unknown. Derived from the
    /// same version rules that enable each feature, so the summary cannot disagree with them.
    var featureSupport: [PassCLIFeatureSupport] {
        guard let version else { return [] }
        let tested = Self.testedReleases.contains(version)
        func status(minimum: PassCLIVersion) -> PassCLIFeatureStatus {
            guard version >= minimum else { return .unsupported(minimumVersion: minimum) }
            return tested ? .supported : .untested
        }
        let fastOfflineSync: PassCLIFeatureStatus = switch snapshotContentProvenance {
        case .completeJSONV1: .supported
        case .unverifiedCompleteJSON: .untested
        case .unavailable: Self.blockedContentReuseVersions.contains(version)
            ? .unsupported(minimumVersion: nil)
            : .unsupported(minimumVersion: Self.minimumUnverifiedContentReuseVersion)
        }
        var rows = [
            PassCLIFeatureSupport(feature: .folders, status: status(minimum: Self.minimumFoldersVersion)),
            PassCLIFeatureSupport(feature: .fastOfflineSync, status: fastOfflineSync)
        ]
        // Older CLIs cannot be refused by vault policy, so "unsupported" would mislead.
        if version >= Self.minimumSensitiveContentPolicyVersion {
            rows.append(PassCLIFeatureSupport(feature: .vaultPasswordPolicy,
                                              status: status(minimum: Self.minimumSensitiveContentPolicyVersion)))
        }
        return rows
    }
}
