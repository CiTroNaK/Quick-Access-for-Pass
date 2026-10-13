import SwiftUI
import Combine

struct RunAuthDecisionsView: View {
    let databaseManager: DatabaseManager
    @State private var decisions: [RunAuthDecision] = []
    @State private var profileNames: [String: String] = [:]  // slug → name
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remembered run decisions (\(decisions.count))")
                .foregroundStyle(.secondary)

            if decisions.isEmpty {
                Text("No remembered decisions.")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            } else {
                RememberedDecisionList(accessibilityLabel: String(localized: "Remembered run decisions")) {
                    ForEach(decisions, id: \.compositeKey) { decision in
                        RunDecisionRow(
                            presentation: RunAuthDecisionRowPresentation(
                                decision: decision,
                                profileName: profileNames[decision.profileSlug] ?? decision.profileSlug
                            )
                        ) {
                            try? databaseManager.removeRunAuthDecision(
                                appIdentifier: decision.appIdentifier,
                                subcommand: decision.subcommand,
                                profileSlug: decision.profileSlug
                            )
                            loadDecisions()
                        }
                    }
                }
            }
        }
        .onAppear { loadDecisions() }
        .onReceive(timer) { _ in loadDecisions() }
    }

    private func loadDecisions() {
        decisions = (try? databaseManager.allRunAuthDecisions()) ?? []
        let profiles = (try? databaseManager.allRunProfiles()) ?? []
        profileNames = Dictionary(uniqueKeysWithValues: profiles.map { ($0.slug, $0.name) })
    }
}

// MARK: - Decision Row

nonisolated struct RunAuthDecisionRowPresentation: Sendable {
    let decision: RunAuthDecision
    let profileName: String

    var bundleID: String { decision.appIdentifier }
    var primaryText: String { RunAuthorizationScope.persistedLabel(for: decision.subcommand) }
    var scopeHelpText: String { decision.subcommand }

    func secondaryText(relativeExpiration: String) -> String {
        let outcome = decision.allowed ? String(localized: "Allowed") : String(localized: "Denied")
        return "\(outcome) · \(profileName) · \(relativeExpiration)"
    }

    var removeHelpText: String {
        String(localized: "Remove (will ask again on next request)")
    }
}

private struct RunDecisionRow: View {
    let presentation: RunAuthDecisionRowPresentation
    let onDelete: () -> Void

    var body: some View {
        RememberedDecisionRow(config: rowConfig, onDelete: onDelete)
            .help(presentation.scopeHelpText)
    }

    private var rowConfig: RememberedDecisionRowConfig {
        RememberedDecisionRowConfig(
            bundleID: presentation.bundleID,
            primaryText: presentation.primaryText,
            secondaryText: presentation.secondaryText(relativeExpiration: relativeExpiration),
            allowed: presentation.decision.allowed,
            removeHelpText: presentation.removeHelpText
        )
    }

    private var relativeExpiration: String {
        FormatHelpers.relativeExpiration(presentation.decision.expiresAt)
    }
}

extension RunAuthorizationScope {
    /// Formats only valid versioned exact fingerprints; legacy/malformed stored keys stay literal.
    nonisolated static func persistedLabel(for key: String) -> String {
        guard key.range(of: "^exact-v1:[0-9a-f]{64}$", options: .regularExpression) != nil,
              key.utf8.count == "exact-v1:".utf8.count + 64 else { return key }
        let fingerprint = String(key.dropFirst("exact-v1:".count).prefix(12))
        return String(
            localized: "Exact command (\(fingerprint))",
            comment: """
            Remembered exact-command decision. Placeholder is the first 12 lowercase hexadecimal characters of a SHA256 fingerprint, \
            not a command or secret. The complete fingerprint is available in help text.
            """
        )
    }
}
