import SwiftUI

/// An operation-free decorative subtree; removal ends the repeating animation's view lifetime.
struct PulsingStatusAura: View {
    let color: Color
    @State private var pulsePhase = false
    @Environment(\.settingsPulseLifecycleObserver) private var lifecycleObserver

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .scaleEffect(pulsePhase ? 2.0 : 1.0)
            .opacity(pulsePhase ? 0.0 : 0.45)
            .onAppear {
                lifecycleObserver?.appearanceChanged(true)
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulsePhase = true
                }
            }
            .onDisappear { lifecycleObserver?.appearanceChanged(false) }
    }
}
