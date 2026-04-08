import SwiftUI
import Combine

struct RunAuthDecisionsView: View {
    let databaseManager: DatabaseManager
    @State private var decisions: [RunAuthDecision] = []
    @State private var profileNames: [String: String] = [:]  // slug → name
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remembered run decisions")
                .foregroundStyle(.secondary)

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

            if decisions.isEmpty {
                Text("No remembered decisions.")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
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
    var primaryText: String { decision.subcommand }

    func secondaryText(relativeExpiration: String) -> String {
        "\(profileName) · \(relativeExpiration)"
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
    }

    private var rowConfig: RememberedDecisionRowConfig {
        RememberedDecisionRowConfig(
            bundleID: presentation.bundleID,
            primaryText: presentation.primaryText,
            secondaryText: presentation.secondaryText(relativeExpiration: relativeExpiration),
            removeHelpText: presentation.removeHelpText
        )
    }

    private var relativeExpiration: String {
        FormatHelpers.relativeExpiration(presentation.decision.expiresAt)
    }
}
