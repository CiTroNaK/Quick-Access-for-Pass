import SwiftUI

extension EnvironmentValues {
    /// Host-only offline settings coordinator. The AutoFill extension never
    /// receives this dependency or offline catalog/cache state.
    @Entry var offlineModeCoordinator: OfflineModeCoordinator?
}
