import Foundation

nonisolated enum PassCLILoginParser {
    private static let urlPattern = #"https?://[^\s<>\"]+"#
    private static let ansiPattern = #"\x1B\[[0-9;]*[a-zA-Z]|\[\d+m"#
    private static let protonLoginPattern = #"https://account\.proton\.me/desktop/login\?[^\s<>\"]+"#

    static func authenticationURL(in output: String) -> URL? {
        let stripped = stripANSI(output)
        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return nil }
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        for match in regex.matches(in: stripped, range: range) {
            guard let swiftRange = Range(match.range, in: stripped),
                  let url = URL(string: String(stripped[swiftRange])),
                  isValidLoginURL(url) else { continue }
            return url
        }
        return nil
    }

    static func sanitizedMessage(from output: String, limit: Int = 160) -> String {
        let stripped = stripANSI(output)
        let redacted = stripped.replacingOccurrences(
            of: protonLoginPattern,
            with: "[Proton login URL redacted]",
            options: .regularExpression
        )
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }

        let marker = "[Proton login URL redacted]"
        if trimmed.contains(marker), trimmed.prefix(limit).contains(marker) == false {
            let prefixLimit = max(0, limit - marker.count - 4)
            return String(trimmed.prefix(prefixLimit)) + "... " + marker
        }

        return String(trimmed.prefix(limit)) + "..."
    }

    static func redactedForCapture(_ output: String) -> String {
        sanitizedMessage(from: output, limit: 4_000)
    }

    private static func isValidLoginURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.host == "account.proton.me",
              url.path == "/desktop/login",
              url.user == nil,
              url.password == nil,
              let fragment = url.fragment,
              fragment.hasPrefix("payload="),
              fragment.count > "payload=".count else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.contains { $0.name == "app" && $0.value == "pass" } == true
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
    }
}
