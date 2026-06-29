import Foundation
import Observation

nonisolated struct PassCLIRecommendedVersionWarning: Sendable, Equatable {
    let activeVersion: PassCLIVersion
    let recommendedVersion: PassCLIVersion

    var message: String {
        let recommendedVersionDescription = recommendedVersion.description
        return String(
            localized: """
            Recommended Pass CLI version is \(recommendedVersionDescription). \
            If the latest bundled CLI causes problems, select an older bundled version \
            and open a GitHub issue so it can be investigated.
            """
        )
    }
}

nonisolated struct PassCLISourceOption: Sendable, Equatable, Identifiable {
    enum Group: String, Sendable, Equatable {
        case automatic
        case installed
        case bundled
        case custom
    }

    let id: String
    let label: String
    let group: Group
    let preference: PassCLISelectionPreference
}

/// Observable source of truth for Pass CLI info surfaced on the Pass CLI settings tab.
/// Owned by AppDelegate, injected via .environment(...). Sole writer is
/// `HealthCheckCoordinator.tickCLI()`, which runs on each CLI probe tick
/// (launch, wake, Settings becomes key, menu-bar "Refresh Now", and every 30 s).
@Observable
@MainActor
final class PassCLIStatusStore {
    var health: PassCLIHealth = .ok
    var identity: PassCLIIdentity?
    var version: String?
    var selection: PassCLISelection = .unresolved(command: "pass-cli")
    var sourceOptions: [PassCLISourceOption] = [
        PassCLISourceOption(
            id: PassCLISelectionPreference.auto.rawValue,
            label: String(localized: "Auto (recommended)"),
            group: .automatic,
            preference: .auto
        ),
        PassCLISourceOption(
            id: PassCLISelectionPreference.custom.rawValue,
            label: String(localized: "Custom path…"),
            group: .custom,
            preference: .custom
        )
    ]
    var latestBundledVersion: PassCLIVersion?
    var recommendedVersionWarning: PassCLIRecommendedVersionWarning?

    init() {}

    func refreshSourceOptions(discovery: PassCLIDiscovery = PassCLIDiscovery()) async {
        let installed = await discovery.installedCandidates()
        let bundled = discovery.bundledCandidates()
        updateSourceOptions(installed: installed, bundled: bundled)
    }

    func updateSourceOptions(installed: [PassCLIInstalledCandidate], bundled: [PassCLIBundledCandidate]) {
        var options: [PassCLISourceOption] = [
            PassCLISourceOption(
                id: PassCLISelectionPreference.auto.rawValue,
                label: String(localized: "Auto (recommended)"),
                group: .automatic,
                preference: .auto
            )
        ]

        options += installed.map { candidate in
            let label = if let displayVersion = candidate.displayVersion {
                String(localized: "\(candidate.path) — \(displayVersion)")
            } else {
                String(localized: "\(candidate.path) — version unknown")
            }
            return PassCLISourceOption(
                id: PassCLISelectionPreference.installed(path: candidate.path).rawValue,
                label: label,
                group: .installed,
                preference: .installed(path: candidate.path)
            )
        }

        if let latest = bundled.first {
            let latestVersionDescription = latest.version.description
            options.append(PassCLISourceOption(
                id: PassCLISelectionPreference.bundled(.latest).rawValue,
                label: String(localized: "Bundled latest (\(latestVersionDescription))"),
                group: .bundled,
                preference: .bundled(.latest)
            ))
        }

        options += bundled.map { candidate in
            let candidateVersionDescription = candidate.version.description
            let label = if candidate.isLatest {
                String(localized: "Bundled \(candidateVersionDescription) (pin this version)")
            } else {
                String(localized: "Bundled \(candidateVersionDescription)")
            }
            return PassCLISourceOption(
                id: PassCLISelectionPreference.bundled(.version(candidate.version.description)).rawValue,
                label: label,
                group: .bundled,
                preference: .bundled(.version(candidate.version.description))
            )
        }

        options.append(PassCLISourceOption(
            id: PassCLISelectionPreference.custom.rawValue,
            label: String(localized: "Custom path…"),
            group: .custom,
            preference: .custom
        ))
        sourceOptions = options
        latestBundledVersion = bundled.first?.version
    }
}
