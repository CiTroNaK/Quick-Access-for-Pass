import Foundation

// MARK: - Show Command
nonisolated extension ProcessIdentifier {
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.panic.Prompt",
        "com.codinn.SecureCRT",
        // Herdr Core hosts its terminals' shells; independent of the Herdr Core integration switches,
        // which only affect header presentation and must not change the SSH cache identity.
        "dev.herdr.core",
    ]

    /// Built-in terminals always show the command; other apps only when the user listed them.
    static func showsCommand(bundleID: String, customApps: [String]) -> Bool {
        terminalBundleIDs.contains(bundleID) || customApps.contains(bundleID)
    }
}
