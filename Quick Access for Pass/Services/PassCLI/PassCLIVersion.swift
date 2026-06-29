import Foundation

nonisolated struct PassCLIVersion: Comparable, CustomStringConvertible, Sendable, Equatable, Hashable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ rawValue: String?) {
        guard let rawValue else { return nil }
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawValue, range: NSRange(rawValue.startIndex..., in: rawValue)),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: rawValue),
              let minorRange = Range(match.range(at: 2), in: rawValue),
              let patchRange = Range(match.range(at: 3), in: rawValue),
              let major = Int(rawValue[majorRange]),
              let minor = Int(rawValue[minorRange]),
              let patch = Int(rawValue[patchRange]) else {
            return nil
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: PassCLIVersion, rhs: PassCLIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
