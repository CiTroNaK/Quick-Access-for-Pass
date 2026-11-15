import Foundation

nonisolated struct RequesterPresentation: Equatable, Sendable {
    let name: String
    let bundleURL: URL?
    let symbolName: String
    let hostID: String?
    let details: HerdrPaneDetails?
    /// Display-only icon replacing the identified app's icon; never changes `bundleURL` or identity.
    var iconOverride: RequesterIcon?

    func replacing(details: HerdrPaneDetails?) -> Self {
        .init(name: name, bundleURL: bundleURL, symbolName: symbolName, hostID: hostID, details: details,
              iconOverride: iconOverride)
    }

    func replacing(iconOverride: RequesterIcon?) -> Self {
        .init(name: name, bundleURL: bundleURL, symbolName: symbolName, hostID: hostID, details: details,
              iconOverride: iconOverride)
    }
}

nonisolated enum RequesterIcon: Equatable, Sendable {
    case bundle(URL)
    case symbol(String)
}
