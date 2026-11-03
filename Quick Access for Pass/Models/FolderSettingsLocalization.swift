import Foundation

/// Localizes fixed presentation text at the view's locale, preserving every interpolated user value.
nonisolated enum FolderSettingsLocalization {
    /// Resource locale selects translations too; String's locale-only initializer merely formats values.
    static func text(_ resource: LocalizedStringResource, locale: Locale) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    static func capabilityMessage(_ availability: FolderFeatureAvailability, locale: Locale) -> String? {
        switch availability {
        case .supported: nil
        case .requiresUpgrade: text("Folders require Pass CLI 2.5.0 or newer.", locale: locale)
        case .checking, .unavailable:
            text("Folder support is not verified for the selected Pass CLI. Existing offline copies and removal remain available.", locale: locale)
        }
    }

    static func counts(selected: Int, usable: Int, locale: Locale) -> String {
        text("\(selected) selected, \(usable) usable", locale: locale)
    }

    static func folderSelections(count: Int, locale: Locale) -> String {
        text("\(count) folder selections", locale: locale)
    }

    static func foldersShown(count: Int, locale: Locale) -> String {
        text("\(count) folders shown", locale: locale)
    }

    /// Every independent source stays visible; the neutral separator is not a plural or an English suffix.
    static func itemPolicyDescription(_ policy: OfflineItemPolicy, locale: Locale) -> String {
        guard !policy.isExcluded else { return text("Not selected", locale: locale) }
        var sources: [String] = []
        if policy.isManuallySelected { sources.append(text("Selected independently", locale: locale)) }
        if policy.vaultSelection != nil { sources.append(text("Included by selected vault", locale: locale)) }
        if !policy.folderSelections.isEmpty { sources.append(text("Included by selected folder", locale: locale)) }
        return sources.isEmpty ? text("Not selected", locale: locale) : sources.joined(separator: " · ")
    }

    static func policyDescription(_ row: OfflineFolderSettingsRow, rows: [OfflineFolderSettingsRow],
                                  vaultSelected: Bool, locale: Locale) -> String {
        policyDescription(row, pathsByID: pathsByID(rows), vaultSelected: vaultSelected, locale: locale)
    }

    /// Build once per render so each row resolves its covering ancestor without a linear scan.
    static func pathsByID(_ rows: [OfflineFolderSettingsRow]) -> [OfflineFolderSettingsRow.ID: String] {
        Dictionary(rows.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
    }

    static func policyDescription(_ row: OfflineFolderSettingsRow, pathsByID: [OfflineFolderSettingsRow.ID: String],
                                  vaultSelected: Bool, locale: Locale) -> String {
        if let ancestor = row.coveringAncestorID,
           let path = pathsByID[OfflineFolderSettingsRow.ID(vaultID: row.vaultID, folderID: ancestor)] {
            return row.isSelected
                ? text("Selected independently; also included by \(path)", locale: locale)
                : text("Included by \(path)", locale: locale)
        }
        if vaultSelected {
            return row.isSelected
                ? text("Selected independently; also included by selected vault", locale: locale)
                : text("Included by selected vault", locale: locale)
        }
        if row.coveringAncestorID != nil {
            return text("Included by selected folder", locale: locale)
        }
        return row.isSelected ? text("Selected independently", locale: locale)
            : text("Not selected", locale: locale)
    }
}
