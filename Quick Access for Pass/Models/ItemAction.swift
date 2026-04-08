import Foundation

nonisolated enum ItemAction: Sendable {
    case copyPassword
    case copyUsername
    case copyTotp
    case copyPrimary
    case openURL

    var sfSymbol: String {
        switch self {
        case .copyPassword: "key.fill"
        case .copyUsername: "person.fill"
        case .copyTotp: "clock.fill"
        case .copyPrimary: "doc.on.doc.fill"
        case .openURL: "globe"
        }
    }
}
