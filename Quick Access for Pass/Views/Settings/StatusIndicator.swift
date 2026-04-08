import SwiftUI

/// Small status indicator with an optional pulsing glow.
///
/// Color and shape vary by state so users with color-vision differences still get
/// an unambiguous signal (CLAUDE.md "Differentiate Without Color" rule):
///   - `.ok`          → filled circle (green)
///   - `.degraded`    → exclamationmark.triangle.fill SF Symbol (orange)
///   - `.unreachable` → xmark.octagon.fill SF Symbol (red)
///   - `.disabled`    → outlined circle (secondary)
///
/// The pulse animation (expanding aura) is shown for every active state
/// (`.ok`/`.degraded`/`.unreachable`) — only `.disabled` stays static. The animation
/// is gated on `accessibilityReduceMotion` — when reduce-motion is on the colored
/// indicator remains visible but static.
///
/// Note: `Image(systemName:).font(.system(size:))` is intentionally fixed-size here.
/// This is a traffic-light LED, not body text; scaling with Dynamic Type would make
/// the footer layout unstable.
struct StatusIndicator: View {
    let state: ProxyHealthState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Pulsing aura — only when there's something to draw attention to.
            // Extracted into its own view so each re-insertion (e.g., when the user
            // toggles the proxy off/on) gets a fresh @State and the animation
            // actually re-triggers. Keying the view on `state` forces SwiftUI to
            // recreate the aura whenever the state changes, ensuring the pulse
            // restarts cleanly even when state transitions between active values.
            if shouldPulse && !reduceMotion {
                PulsingAura(color: tint)
                    .id(state)
            }

            // Foreground indicator: filled/outlined circle for ok/disabled,
            // SF Symbol for degraded/unreachable (shape carries the meaning).
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

    private var shouldPulse: Bool {
        switch state {
        case .ok, .degraded, .unreachable: return true
        case .disabled:                    return false
        }
    }
}

/// Self-contained pulsing aura. Owning its own `@State` means SwiftUI gives it a
/// fresh `pulsePhase = false` whenever the view is inserted, so `onAppear` can kick
/// off the `withAnimation(...).repeatForever(...)` cleanly every time. Keying the
/// caller on the state forces recreation on state changes.
private struct PulsingAura: View {
    let color: Color
    @State private var pulsePhase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .scaleEffect(pulsePhase ? 2.0 : 1.0)
            .opacity(pulsePhase ? 0.0 : 0.45)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulsePhase = true
                }
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
}
