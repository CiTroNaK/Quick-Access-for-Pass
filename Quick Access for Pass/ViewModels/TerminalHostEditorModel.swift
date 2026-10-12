import Foundation
import Observation

/// Holds unsaved terminal-host editor input and validates it before one store mutation.
@MainActor @Observable final class TerminalHostEditorModel {
    let store: TerminalHostStore
    let entryID: String?
    var displayName: String
    var executablePath: String
    private(set) var errorMessage: String?

    /// Creates an add editor or an editor initialized from the current saved entry.
    init(store: TerminalHostStore, entryID: String? = nil) {
        self.store = store
        self.entryID = entryID
        let entry = entryID.flatMap { id in store.entries.first { $0.id == id } }
        displayName = entry?.displayName ?? ""
        executablePath = entry?.executablePath ?? ""
    }

    /// Whether this edit may change only the Herdr display name, not its installation path.
    var isNameOnly: Bool {
        guard let entryID else { return false }
        return store.entries.first(where: { $0.id == entryID })?.provider == .herdr
    }

    /// Saves all editor fields atomically, leaving the model open with an error on failure.
    func save() -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .newlines) == nil,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            errorMessage = String(localized: "Enter a nonempty, single-line terminal host name.")
            return false
        }

        if let entryID {
            guard var latest = store.entries.first(where: { $0.id == entryID }) else {
                errorMessage = String(localized: "This terminal host is no longer available.")
                return false
            }
            latest.displayName = name
            if !isNameOnly {
                guard let url = Self.executableURL(from: executablePath) else {
                    errorMessage = String(localized: "Enter an absolute executable path or a path beginning with ~/.")
                    return false
                }
                latest.executablePath = url.path
            }
            do {
                try store.update(latest)
                errorMessage = nil
                return true
            } catch {
                errorMessage = Self.message(for: error)
                return false
            }
        }

        guard let url = Self.executableURL(from: executablePath) else {
            errorMessage = String(localized: "Enter an absolute executable path or a path beginning with ~/.")
            return false
        }
        do {
            try store.addExecutable(at: url, displayName: name)
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    static func executableURL(from input: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.rangeOfCharacter(from: .controlCharacters) == nil,
              !path.contains("$"), !path.contains("`"), !path.contains("\\"),
              !path.contains("*") && !path.contains("?") && !path.contains("[") else { return nil }
        if path == "~" { return homeDirectory.standardizedFileURL }
        if path.hasPrefix("~/") {
            return homeDirectory.appending(path: String(path.dropFirst(2))).standardizedFileURL
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func message(for error: Error) -> String {
        switch error as? TerminalHostStore.StoreError {
        case .invalidPreferences:
            String(localized: "Reset unreadable terminal host settings before making changes.")
        case .invalidExecutable:
            String(localized: "Choose an available executable file.")
        case .duplicateExecutable:
            String(localized: "This executable already has a terminal host mapping.")
        case .invalidEntry:
            String(localized: "Enter a nonempty, single-line terminal host name.")
        case nil:
            String(localized: "Terminal host settings could not be updated.")
        }
    }
}
