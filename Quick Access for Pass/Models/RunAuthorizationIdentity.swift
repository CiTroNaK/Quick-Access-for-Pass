import Foundation

nonisolated struct RunAuthorizationIdentity: Hashable, Sendable {
    let matchType: RunAuthorizationMatchType
    let matchValue: String

    private init(matchType: RunAuthorizationMatchType, matchValue: String) {
        self.matchType = matchType
        self.matchValue = matchValue
    }

    init?(exactDigest: String) {
        let bytes = Array(exactDigest.utf8)
        guard bytes.count == 64,
              bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        self.init(matchType: .exactArgumentsV1, matchValue: exactDigest)
    }

    init(prefix: String) {
        self.init(matchType: .commandPrefixV1, matchValue: prefix)
    }
}
