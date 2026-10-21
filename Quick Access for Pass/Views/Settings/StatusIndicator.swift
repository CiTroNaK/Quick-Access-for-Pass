import SwiftUI

/// Small status indicator with an optional pulsing glow.
///
/// Color and shape distinguish status without relying on color alone. Only an
/// explicitly eligible Settings tab admits the decorative aura. Reduce Motion
/// suppresses the aura without removing the foreground status indicator.
///
/// Symbol sizes are intentionally fixed: this is a traffic-light LED, not body text.
struct StatusIndicator: View {
    let state: ProxyHealthState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsAnimationsActive) private var animationsActive

    var body: some View {
        StatusIndicatorContent(state: state, animationsActive: animationsActive, reduceMotion: reduceMotion)
    }

    /// Determines whether an active status may show its decorative pulse.
    nonisolated static func isPulseEnabled(state: ProxyHealthState, animationsActive: Bool, reduceMotion: Bool) -> Bool {
        guard animationsActive, !reduceMotion else { return false }
        switch state {
        case .ok, .degraded, .unreachable: return true
        case .disabled:                    return false
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusIndicator(state: .ok(detail: "3 keys"))
        StatusIndicator(state: .degraded(.emptyIdentities))
        StatusIndicator(state: .unreachable(.probeFailed))
        StatusIndicator(state: .disabled)
    }
    .padding()
    .environment(\.settingsAnimationsActive, true)
}
