import SwiftUI

struct RunStatusRow: View {
    let state: ProxyHealthState

    var body: some View {
        HStack(spacing: 6) {
            StatusIndicator(state: state)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
    }

    private var statusText: String {
        switch state {
        case .ok:                      return String(localized: "Running")
        case .degraded(let reason):    return reason.userFacingText
        case .unreachable(let reason): return String(localized: "Unreachable — \(reason.userFacingText)")
        case .disabled:                return String(localized: "Disabled")
        }
    }

    private var voiceOverLabel: String {
        switch state {
        case .ok:                      return String(localized: "Run proxy running")
        case .degraded(let reason):    return String(localized: "Run proxy: \(reason.userFacingText)")
        case .unreachable(let reason): return String(localized: "Run proxy unreachable — \(reason.userFacingText)")
        case .disabled:                return String(localized: "Run proxy disabled")
        }
    }
}

#Preview("OK") { RunStatusRow(state: .ok()).frame(width: 420) }
#Preview("Degraded") { RunStatusRow(state: .degraded(.probeFailed)).frame(width: 420) }
#Preview("Unreachable") { RunStatusRow(state: .unreachable(.passCLINotLoggedIn)).frame(width: 420) }
#Preview("Disabled") { RunStatusRow(state: .disabled).frame(width: 420) }
