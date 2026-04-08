import SwiftUI

extension EnvironmentValues {
    /// Database manager for views that need direct DB access (settings
    /// tabs, vault filter, auth-decision lists). Injected at the
    /// settings window root via
    /// `.environment(\.databaseManager, databaseManager)`. Views that
    /// read this without it being injected see `nil` and should
    /// degrade gracefully (typically by showing an empty state).
    @Entry var databaseManager: DatabaseManager?
}
