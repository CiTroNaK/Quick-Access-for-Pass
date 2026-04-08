import Foundation

nonisolated struct PendingLockContext: Equatable, Sendable {
    nonisolated enum Kind: Sendable {
        case ssh
        case run
    }

    let kind: Kind
    let appName: String
    let host: String?
    let keySummary: String?
    let profileName: String?
    let commandSummary: String?

    static func ssh(appName: String, host: String?, keySummary: String?) -> Self {
        Self(
            kind: .ssh,
            appName: appName,
            host: host,
            keySummary: keySummary,
            profileName: nil,
            commandSummary: nil
        )
    }

    static func run(appName: String, profileName: String?, commandSummary: String?) -> Self {
        Self(
            kind: .run,
            appName: appName,
            host: nil,
            keySummary: nil,
            profileName: profileName,
            commandSummary: commandSummary
        )
    }

    var primaryLine: String {
        switch kind {
        case .ssh:
            String(localized: "SSH request from \(appName)")
        case .run:
            String(localized: "Run request from \(appName)")
        }
    }

    var detailLine: String? {
        switch kind {
        case .ssh:
            let parts = [
                host.map { String(localized: "Host: \($0)") },
                keySummary.map { String(localized: "Key: \($0)") },
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .run:
            let parts = [
                profileName.map { String(localized: "Profile: \($0)") },
                commandSummary.map { String(localized: "Command: \($0)") },
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}
