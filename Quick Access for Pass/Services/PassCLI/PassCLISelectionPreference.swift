import Foundation

nonisolated enum BundledPassCLISelection: Sendable, Equatable, Hashable {
    case latest
    case version(String)

    init?(rawValue: String) {
        if rawValue == "latest" {
            self = .latest
        } else if PassCLIVersion(rawValue) != nil {
            self = .version(rawValue)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .latest: return "latest"
        case .version(let version): return version
        }
    }
}

nonisolated enum PassCLISelectionPreference: Sendable, Equatable, Hashable {
    case auto
    case custom
    case installed(path: String)
    case bundled(BundledPassCLISelection)

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "auto" {
            self = .auto
        } else if trimmed == "custom" {
            self = .custom
        } else if trimmed.hasPrefix("installed:") {
            let path = String(trimmed.dropFirst("installed:".count))
            guard path.isEmpty == false else { return nil }
            self = .installed(path: path)
        } else if trimmed.hasPrefix("bundled:") {
            let rawSelection = String(trimmed.dropFirst("bundled:".count))
            guard let selection = BundledPassCLISelection(rawValue: rawSelection) else { return nil }
            self = .bundled(selection)
        } else {
            return nil
        }
    }

    static func resolved(rawValue: String?, legacyCustomPath: String?) -> PassCLISelectionPreference {
        if let rawValue {
            return PassCLISelectionPreference(rawValue: rawValue) ?? .auto
        }
        let legacy = legacyCustomPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return legacy.isEmpty ? .auto : .custom
    }

    var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .custom: return "custom"
        case .installed(let path): return "installed:\(path)"
        case .bundled(let selection): return "bundled:\(selection.rawValue)"
        }
    }
}
