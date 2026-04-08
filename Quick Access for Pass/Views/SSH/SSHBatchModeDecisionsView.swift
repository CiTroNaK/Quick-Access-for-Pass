import SwiftUI

struct SSHBatchModeDecisionsView: View {
    let databaseManager: DatabaseManager
    @State private var decisions: [SSHBatchModeDecision] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SSH probe decisions")
                .foregroundStyle(.secondary)
            Text("Keys allowed or blocked for non-interactive probes (BatchMode).")
                .font(.caption)
                .foregroundStyle(.tertiary)

            ForEach(decisions, id: \.compositeKey) { decision in
                HStack(spacing: 6) {
                    Image(systemName: decision.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(decision.allowed ? .green : .red)
                        .accessibilityLabel(decision.allowed ? String(localized: "Allowed") : String(localized: "Blocked"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(decision.keyName ?? "Key \(decision.keyFingerprint.prefix(16))...")
                            .font(.callout)
                        Text(decision.host)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle.fill") {
                        try? databaseManager.removeBatchModeDecision(keyFingerprint: decision.keyFingerprint, host: decision.host)
                        loadDecisions()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .help(Text("Remove (will ask again on next probe)"))
                }
            }

            if decisions.isEmpty {
                Text("No decisions yet. Decisions appear after SSH probes are intercepted.")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
        }
        .onAppear { loadDecisions() }
    }

    private func loadDecisions() {
        decisions = (try? databaseManager.allBatchModeDecisions()) ?? []
    }
}
