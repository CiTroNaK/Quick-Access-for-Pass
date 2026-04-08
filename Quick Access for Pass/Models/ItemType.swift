import SwiftUI

nonisolated enum ItemType: String, Codable, Sendable {
    case login = "login"
    case creditCard = "credit-card"
    case note = "note"
    case identity = "identity"
    case alias = "alias"
    case sshKey = "ssh-key"
    case wifi = "wifi"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .login: String(localized: "Login")
        case .creditCard: String(localized: "Credit Card")
        case .note: String(localized: "Note")
        case .identity: String(localized: "Identity")
        case .alias: String(localized: "Alias")
        case .sshKey: String(localized: "SSH Key")
        case .wifi: String(localized: "Wi-Fi")
        case .custom: String(localized: "Custom")
        }
    }

    var sfSymbol: String {
        switch self {
        case .login: "person.crop.circle.fill"
        case .creditCard: "creditcard.fill"
        case .note: "note.text"
        case .identity: "person.text.rectangle.fill"
        case .alias: "at"
        case .sshKey: "key.fill"
        case .wifi: "wifi"
        case .custom: "doc.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .login: .blue
        case .creditCard: .orange
        case .note: .yellow
        case .identity: .purple
        case .alias: .cyan
        case .sshKey: .green
        case .wifi: .teal
        case .custom: .gray
        }
    }
}
