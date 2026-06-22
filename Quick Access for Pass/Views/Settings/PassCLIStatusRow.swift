import SwiftUI

struct PassCLIStatusRow: View {
    let health: PassCLIHealth
    let identity: PassCLIIdentity?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            if let badge = identityBadge {
                Spacer(minLength: 8)
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.green.opacity(0.15), in: Capsule())
                    .help(badge)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverLabel)
    }

    private var indicatorColor: Color {
        switch health {
        case .ok:            return .green
        case .notLoggedIn:   return .yellow
        case .notInstalled,
             .failed:        return .red
        }
    }

    private var statusText: String {
        switch health {
        case .ok:                   return String(localized: "Connected")
        case .notLoggedIn:          return String(localized: "Not logged in")
        case .notInstalled:         return String(localized: "pass-cli not found")
        case .failed(let reason):   return String(localized: "Error — \(reason)")
        }
    }

    private var identityBadge: String? {
        guard case .ok = health, let identity else { return nil }
        return identity.displayName
    }

    private var voiceOverLabel: String {
        switch health {
        case .ok:
            if let identity, let displayName = identity.displayName {
                if identity.isPersonalAccessTokenSession {
                    return String(localized: "Pass CLI connected using token \(displayName)")
                }
                return String(localized: "Pass CLI connected as \(displayName)")
            }
            return String(localized: "Pass CLI connected")
        case .notLoggedIn:          return String(localized: "Pass CLI not logged in")
        case .notInstalled:         return String(localized: "Pass CLI not found")
        case .failed(let reason):   return String(localized: "Pass CLI error — \(reason)")
        }
    }
}

#Preview("OK with identity") {
    PassCLIStatusRow(
        health: .ok,
        identity: PassCLIIdentity(username: "johndoe", email: "john@example.com", releaseTrack: "stable")
    ).frame(width: 420)
}
#Preview("OK no identity") {
    PassCLIStatusRow(health: .ok, identity: nil).frame(width: 420)
}
#Preview("Not logged in") {
    PassCLIStatusRow(health: .notLoggedIn, identity: nil).frame(width: 420)
}
#Preview("Not installed") {
    PassCLIStatusRow(health: .notInstalled, identity: nil).frame(width: 420)
}
#Preview("Failed") {
    PassCLIStatusRow(health: .failed(reason: "connection reset"), identity: nil).frame(width: 420)
}
