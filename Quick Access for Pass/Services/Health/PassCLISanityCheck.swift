import Foundation

nonisolated struct PassCLIIdentity: Sendable, Equatable, Decodable {
    let username: String?
    let email: String?
    let releaseTrack: String?
    let personalAccessTokenName: String?

    init(
        username: String?,
        email: String?,
        releaseTrack: String?,
        personalAccessTokenName: String? = nil
    ) {
        self.username = username
        self.email = email
        self.releaseTrack = releaseTrack
        self.personalAccessTokenName = personalAccessTokenName
    }

    var displayName: String? {
        personalAccessTokenName ?? username
    }

    var isPersonalAccessTokenSession: Bool {
        personalAccessTokenName != nil
    }

    private enum CodingKeys: String, CodingKey {
        case username
        case email
        case releaseTrack = "release_track"
        case personalAccessTokenName = "personal_access_token_name"
    }
}

nonisolated enum PassCLIHealth: Sendable, Equatable {
    case ok
    case notLoggedIn
    case notInstalled
    case failed(reason: String)
}

/// Authenticated CLI health and identity decoded from the same command response.
nonisolated struct PassCLIAuthenticatedProbeOutcome: Sendable, Equatable {
    let health: PassCLIHealth
    let identity: PassCLIIdentity?
}

/// Runs and classifies Pass CLI health and metadata probes.
nonisolated enum PassCLISanityCheck {
    static let timeoutSeconds: TimeInterval = 5

    /// Checks authenticated CLI health and returns identity metadata from the same response.
    static func checkAuthenticatedHealth(
        cliPath: String,
        runner: CLIRunning
    ) async -> PassCLIAuthenticatedProbeOutcome {
        do {
            let data = try await runner.run(
                executablePath: cliPath,
                arguments: ["info", "--output", "json"],
                timeout: timeoutSeconds
            )
            return PassCLIAuthenticatedProbeOutcome(
                health: .ok,
                identity: try? JSONDecoder().decode(PassCLIIdentity.self, from: data)
            )
        } catch CLIError.notInstalled {
            return PassCLIAuthenticatedProbeOutcome(health: .notInstalled, identity: nil)
        } catch let error as CLIError {
            let health: PassCLIHealth = if error.isAuthError {
                .notLoggedIn
            } else {
                .failed(reason: Self.failureReason(for: error))
            }
            return PassCLIAuthenticatedProbeOutcome(health: health, identity: nil)
        } catch {
            return PassCLIAuthenticatedProbeOutcome(
                health: .failed(reason: Self.failureReason(for: error)),
                identity: nil
            )
        }
    }

    /// Returns a fixed, non-sensitive reason suitable for user-visible and public-log surfaces.
    private static func failureReason(for error: Error) -> String {
        if case CLIError.timeout = error {
            return String(localized: "Pass CLI health check timed out")
        }
        return String(localized: "Pass CLI health check failed")
    }

    /// Returns the CLI version string from `pass-cli --version`, trimmed and stripped
    /// of a leading "pass-cli " prefix if present. Returns nil on any failure.
    static func fetchVersion(cliPath: String, runner: CLIRunning) async -> String? {
        do {
            let data = try await runner.run(
                executablePath: cliPath,
                arguments: ["--version"],
                timeout: timeoutSeconds
            )
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prefix = "pass-cli "
            if raw.hasPrefix(prefix) {
                return String(raw.dropFirst(prefix.count))
            }
            return raw.isEmpty ? nil : raw
        } catch {
            return nil
        }
    }
}
