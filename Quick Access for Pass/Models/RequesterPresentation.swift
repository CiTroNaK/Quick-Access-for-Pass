import Foundation

nonisolated struct RequesterPresentation: Equatable, Sendable {
    let name: String
    let bundleURL: URL?
    let symbolName: String
    let hostID: String?
    let details: HerdrPaneDetails?
}
