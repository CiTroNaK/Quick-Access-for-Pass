import Foundation

nonisolated enum RunAuthorizationMatchType: String, Codable, Hashable, Sendable {
    case exactArgumentsV1 = "exact-argv-v1"
    case commandPrefixV1 = "command-prefix-v1"
}
