import Foundation

extension Notification.Name {
    static let refreshRequested = Notification.Name("refreshRequested")
    static let resetDatabaseRequested = Notification.Name("resetDatabaseRequested")
    static let passCLILoginRequested = Notification.Name("passCLILoginRequested")
}
