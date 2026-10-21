import SwiftUI

/// The actual status presentation, separated from read-only system environment inputs.
/// Tests may drive motion transitions here without changing system preferences or private environment keys.
struct StatusIndicatorContent: View {
    let state: ProxyHealthState
    let animationsActive: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if StatusIndicator.isPulseEnabled(state: state, animationsActive: animationsActive, reduceMotion: reduceMotion) {
                // A fresh identity/state restarts the aura on re-admission and active-status changes.
                PulsingStatusAura(color: tint)
                    .id(state)
            }
            indicator
                .foregroundStyle(tint)
        }
        .frame(width: 12, height: 12)
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .ok:
            Circle().frame(width: 7, height: 7)
        case .degraded:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
        case .unreachable:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 10, weight: .semibold))
        case .disabled:
            Circle()
                .stroke(tint, lineWidth: 1.5)
                .frame(width: 7, height: 7)
        }
    }

    private var tint: Color {
        switch state {
        case .ok:          return .green
        case .degraded:    return .orange
        case .unreachable: return .red
        case .disabled:    return .secondary
        }
    }
}
