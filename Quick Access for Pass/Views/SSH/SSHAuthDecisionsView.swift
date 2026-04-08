import SwiftUI
import Combine

struct SSHAuthDecisionsView: View {
    let databaseManager: DatabaseManager
    @State private var decisions: [SSHAuthDecision] = []
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remembered SSH decisions")
                .foregroundStyle(.secondary)

            ForEach(decisions, id: \.compositeKey) { decision in
                SSHDecisionRow(
                    presentation: SSHDecisionRowPresentation(decision: decision)
                ) {
                    try? databaseManager.removeAuthDecision(
                        appIdentifier: decision.appIdentifier,
                        keyFingerprint: decision.keyFingerprint
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
        decisions = (try? databaseManager.allAuthDecisions()) ?? []
    }
}

// MARK: - Decision Row

nonisolated struct SSHDecisionRowPresentation: Sendable {
    let decision: SSHAuthDecision

    private var parts: [String] {
        decision.appIdentifier.split(separator: ":", maxSplits: 2).map(String.init)
    }

    var bundleID: String { parts[0] }
    private var host: String? { parts.count > 1 ? parts[1] : nil }
    private var command: String? { parts.count > 2 ? parts[2] : nil }

    private var appName: String {
        bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
    }

    var primaryText: String {
        if let command { return command }
        if let host { return host }
        return appName
    }

    func secondaryText(relativeExpiration: String) -> String {
        var components: [String] = []
        if command != nil, let host {
            components.append(host)
        } else if host != nil {
            components.append(appName)
        }
        components.append(relativeExpiration)
        return components.joined(separator: " · ")
    }

    var removeHelpText: String {
        String(localized: "Remove (will ask again on next request)")
    }

    func rowConfig(relativeExpiration: String) -> RememberedDecisionRowConfig {
        RememberedDecisionRowConfig(
            bundleID: bundleID,
            primaryText: primaryText,
            secondaryText: secondaryText(relativeExpiration: relativeExpiration),
            removeHelpText: removeHelpText
        )
    }
}

private struct SSHDecisionRow: View {
    let presentation: SSHDecisionRowPresentation
    let onDelete: () -> Void

    var body: some View {
        RememberedDecisionRow(config: rowConfig, onDelete: onDelete)
    }

    private var rowConfig: RememberedDecisionRowConfig {
        presentation.rowConfig(relativeExpiration: relativeExpiration)
    }

    private var relativeExpiration: String {
        FormatHelpers.relativeExpiration(presentation.decision.expiresAt)
    }
}
