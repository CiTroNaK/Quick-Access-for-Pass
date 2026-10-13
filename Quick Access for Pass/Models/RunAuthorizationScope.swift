import CryptoKit
import Foundation

/// A matching key and transient display label for an exact argv or explicit broader prefix.
nonisolated struct RunAuthorizationScope: Hashable, Sendable {
    let key: String
    let label: String
    let isExact: Bool

    private init(key: String, label: String, isExact: Bool) {
        self.key = key
        self.label = label
        self.isExact = isExact
    }

    /// Fingerprints the complete ordered literal UTF-8 argv, without normalization or shell parsing.
    /// Returns nil only for an empty vector or empty executable. The digest is not encryption.
    static func exact(command: [String]) -> RunAuthorizationScope? {
        guard let executable = command.first, !executable.isEmpty else { return nil }
        var input = Data("quick-access.run.exact-v1".utf8)
        input.append(0)
        appendCount(command.count, to: &input)
        for argument in command {
            let bytes = Data(argument.utf8)
            appendCount(bytes.count, to: &input)
            input.append(bytes)
        }
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        // Quoted, escaped Swift string displays retain empty arguments and argument boundaries;
        // this is display text, never a shell command or a persisted matching identity.
        let label = command.map { $0.debugDescription }.joined(separator: " ")
        return RunAuthorizationScope(key: "exact-v1:" + digest, label: label, isExact: true)
    }

    /// Preserves the existing explicit broader prefix's literal matching key and display label.
    static func prefix(_ value: String) -> RunAuthorizationScope {
        RunAuthorizationScope(key: value, label: value, isExact: false)
    }

    private static func appendCount(_ count: Int, to data: inout Data) {
        var bigEndian = UInt64(count).bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
