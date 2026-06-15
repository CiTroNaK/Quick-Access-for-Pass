import Foundation

extension PassCLISelection {
    var loginRequiredMessage: String {
        switch self {
        case .custom, .system:
            return String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in. You can also run `pass-cli login` in Terminal.")
        case .bundled, .unresolved:
            return String(localized: "Pass CLI is logged out. Open Settings → Pass CLI to log in.")
        }
    }

    var sshLoginRequiredMessage: String {
        switch self {
        case .custom, .system:
            return String(localized: "SSH agent requires Pass CLI login. Open Settings → Pass CLI to log in. You can also run `pass-cli login` in Terminal.")
        case .bundled, .unresolved:
            return String(localized: "SSH agent requires Pass CLI login. Open Settings → Pass CLI to log in.")
        }
    }
}
