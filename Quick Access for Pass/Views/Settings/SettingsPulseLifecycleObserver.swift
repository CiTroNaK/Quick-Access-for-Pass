import Foundation

/// Host-local observation of decorative aura lifetime, with stable identity across view updates.
@MainActor
final class SettingsPulseLifecycleObserver: Equatable {
    private let onAppearanceChanged: @MainActor @Sendable (Bool) -> Void

    init(onAppearanceChanged: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onAppearanceChanged = onAppearanceChanged
    }

    /// Reports only aura presence, never status content or requester identity.
    func appearanceChanged(_ isPresent: Bool) {
        onAppearanceChanged(isPresent)
    }

    nonisolated static func == (lhs: SettingsPulseLifecycleObserver, rhs: SettingsPulseLifecycleObserver) -> Bool {
        lhs === rhs
    }
}
