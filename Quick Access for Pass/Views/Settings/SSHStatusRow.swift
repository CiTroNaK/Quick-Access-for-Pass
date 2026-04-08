import SwiftUI

struct SSHStatusRow: View {
    let state: ProxyHealthState

    var body: some View {
        HStack(spacing: 6) {
            StatusIndicator(state: state)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let badge = keyCountBadge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.green.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
    }

    /// The short visible status text (no "SSH agent:" prefix).
    private var statusText: String {
        switch state {
        case .ok:                      return String(localized: "Running")
        case .degraded(let reason):    return reason.userFacingText
        case .unreachable(let reason): return String(localized: "Unreachable — \(reason.userFacingText)")
        case .disabled:                return String(localized: "Disabled")
        }
    }

    /// The key-count badge text, only when state is `.ok` with a detail.
    private var keyCountBadge: String? {
        guard case .ok(let detail?) = state else { return nil }
        return detail
    }

    /// Full VoiceOver phrase including the "SSH agent:" prefix that was dropped visually.
    private var voiceOverLabel: String {
        switch state {
        case .ok(let detail?):         return String(localized: "SSH agent running with \(detail)")
        case .ok(nil):                 return String(localized: "SSH agent running")
        case .degraded(let reason):    return String(localized: "SSH agent: \(reason.userFacingText)")
        case .unreachable(let reason): return String(localized: "SSH agent unreachable — \(reason.userFacingText)")
        case .disabled:                return String(localized: "SSH agent disabled")
        }
    }
}

#Preview("OK with keys") { SSHStatusRow(state: .ok(detail: "3 keys")).frame(width: 420) }
#Preview("OK one key") { SSHStatusRow(state: .ok(detail: "1 key")).frame(width: 420) }
#Preview("Degraded") { SSHStatusRow(state: .degraded(.emptyIdentities)).frame(width: 420) }
#Preview("Unreachable") { SSHStatusRow(state: .unreachable(.probeFailed)).frame(width: 420) }
#Preview("Disabled") { SSHStatusRow(state: .disabled).frame(width: 420) }
