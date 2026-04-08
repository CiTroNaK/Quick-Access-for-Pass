import Foundation

nonisolated struct PassCLIIdentity: Sendable, Equatable, Decodable {
    let username: String
    let email: String
    let releaseTrack: String

    private enum CodingKeys: String, CodingKey {
        case username
        case email
        case releaseTrack = "release_track"
    }
}

nonisolated enum PassCLIHealth: Sendable, Equatable {
    case ok
    case notLoggedIn
    case notInstalled
    case failed(reason: String)
}

/// On-demand pass-cli login health check. Runs a cheap login-gated command and classifies
/// the result. NOT called from the periodic tick — only at app launch, wake from sleep,
/// and when the Settings window becomes key. Uses `pass-cli test` — the purpose-built
/// connectivity probe with no side effects.
nonisolated enum PassCLISanityCheck {
    static let timeoutSeconds: TimeInterval = 5

    static func checkLoginStatus(cliPath: String, runner: CLIRunning) async -> PassCLIHealth {
        do {
            _ = try await runner.run(
                executablePath: cliPath,
                arguments: ["test"],
                timeout: timeoutSeconds
            )
            return .ok
        } catch CLIError.notInstalled {
            return .notInstalled
        } catch let error as CLIError {
            if error.isAuthError {
                return .notLoggedIn
            }
            return .failed(reason: Self.sanitize(error.localizedDescription))
        } catch {
            return .failed(reason: Self.sanitize(error.localizedDescription))
        }
    }

    /// Strips ANSI escape codes and truncates to a reasonable length for UI display.
    private static func sanitize(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[a-zA-Z]|\\[\\d+m",
            with: "",
            options: .regularExpression
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 120 {
            return String(trimmed.prefix(120)) + "..."
        }
        return trimmed
    }

    /// Returns the current account identity from `pass-cli info --output json`,
    /// or nil on any failure. Cosmetic only — never blocks or fails health signaling.
    static func fetchIdentity(cliPath: String, runner: CLIRunning) async -> PassCLIIdentity? {
        do {
            let data = try await runner.run(
                executablePath: cliPath,
                arguments: ["info", "--output", "json"],
                timeout: timeoutSeconds
            )
            return try JSONDecoder().decode(PassCLIIdentity.self, from: data)
        } catch {
            return nil
        }
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
