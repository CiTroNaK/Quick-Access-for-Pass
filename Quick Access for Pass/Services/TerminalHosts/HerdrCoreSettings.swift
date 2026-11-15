import AppKit
import Foundation
import Observation

/// Herdr Core's Integrations switches, kept apart from the terminal-host store. Open prompts observe them so
/// turning either switch off clears Core context that is already displayed.
@MainActor @Observable final class HerdrCoreSettings {
    var isEnabled: Bool {
        didSet { persist(isEnabled, forKey: DefaultsKey.herdrCoreContextEnabled) }
    }
    /// The "Show workspace, pane title and directory" switch.
    var showsDetails: Bool {
        didSet { persist(showsDetails, forKey: DefaultsKey.herdrCoreShowDetails) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: DefaultsKey.herdrCoreContextEnabled) as? Bool ?? true
        showsDetails = defaults.object(forKey: DefaultsKey.herdrCoreShowDetails) as? Bool ?? true
    }

    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private func persist(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        // Snapshot callbacks so observers can remove themselves during notification.
        for handler in Array(observers.values) { handler() }
    }

    /// Where Herdr Core is installed, for display only; recognition never depends on it. Checks the installer's
    /// commands (`hc`, then `herdr-core`) in `~/.local/bin`, then its bundle in `~/.local/share/herdr-core/current`,
    /// then a `Herdr Core.app` registered with Launch Services.
    nonisolated static func installedLocation(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        locateApp: () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: HerdrCoreTerminalResolver.coreBundleIdentifier) }
    ) -> String? {
        let home = homeDirectory as NSString
        for command in [".local/bin/hc", ".local/bin/herdr-core"].map(home.appendingPathComponent)
        where FileManager.default.isExecutableFile(atPath: command) {
            return command
        }
        let bundle = home.appendingPathComponent(".local/share/herdr-core/current")
        if FileManager.default.isExecutableFile(atPath: bundle + "/Contents/MacOS/herdr-core") { return bundle }
        return locateApp()?.path
    }
}
