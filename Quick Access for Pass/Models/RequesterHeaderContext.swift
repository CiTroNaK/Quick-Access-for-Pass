import Foundation

/// A compact, display-only row derived from untrusted requester context.
nonisolated struct RequesterHeaderContext {
    /// Identifies the localized label used for a context row.
    nonisolated enum Kind: Equatable, Sendable {
        case workspaceAndTab
        case paneTitle
        case workingDirectory
    }

    /// One visible context value; source text is preserved for display.
    nonisolated struct Row: Equatable, Sendable {
        let kind: Kind
        let value: String
    }

    /// Returns useful non-empty context rows, omitting titles that repeat the displayed command.
    static func rows(for presentation: RequesterPresentation, displayedCommand: String?) -> [Row] {
        guard let details = presentation.details else { return [] }
        var rows: [Row] = []
        let labels = [details.workspaceLabel, details.tabLabel].compactMap(nonEmptyValue)
        if !labels.isEmpty {
            rows.append(Row(kind: .workspaceAndTab, value: labels.joined(separator: " / ")))
        }
        if let title = nonEmptyValue(details.paneTitle),
           normalized(title) != normalized(displayedCommand ?? "") {
            rows.append(Row(kind: .paneTitle, value: title))
        }
        if let directory = nonEmptyValue(details.workingDirectory) {
            rows.append(Row(kind: .workingDirectory, value: directory))
        }
        return rows
    }

    private static func nonEmptyValue(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
