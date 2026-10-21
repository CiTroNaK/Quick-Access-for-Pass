import Foundation

nonisolated enum AutoFillConstants {
    static let appGroupIdentifier = "group.codes.petr.quick-access-for-pass"
    static let keychainAccessGroup = "H23TXL6LPT.codes.petr.quick-access-for-pass"
    static let hostBundleIdentifier = "codes.petr.quick-access-for-pass"
    static let extensionBundleIdentifier = "codes.petr.quick-access-for-pass.autofill"
    static let databaseDirectoryName = "QuickAccessForPass"
    static let databaseFileName = "app.db"
    static let brokerDirectoryName = "autofill"
    static let brokerSocketFileName = "broker.sock"

    static func brokerSocketURL(fileManager: FileManager = .default) throws -> URL {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw AutoFillConstantsError.sharedContainerUnavailable
        }
        return containerURL
            .appendingPathComponent(brokerDirectoryName, isDirectory: true)
            .appendingPathComponent(brokerSocketFileName, isDirectory: false)
    }

    static func legacyDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AutoFillConstantsError.applicationSupportUnavailable
        }
        return applicationSupportURL
            .appendingPathComponent(databaseDirectoryName, isDirectory: true)
            .appendingPathComponent(databaseFileName, isDirectory: false)
    }
}

nonisolated enum AutoFillConstantsError: Error {
    case applicationSupportUnavailable
    case sharedContainerUnavailable
}
