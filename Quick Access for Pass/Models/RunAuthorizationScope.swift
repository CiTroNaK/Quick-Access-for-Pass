import CryptoKit
import Foundation

/// A typed authorization identity and transient display label for an exact argv or explicit broader prefix.
nonisolated struct RunAuthorizationScope: Hashable, Sendable {
    let identity: RunAuthorizationIdentity
    let label: String
    let isExact: Bool

    private init(identity: RunAuthorizationIdentity, label: String, isExact: Bool) {
        self.identity = identity
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
        guard let identity = RunAuthorizationIdentity(exactDigest: digest) else { return nil }
        let label = RunCommandDisplayFormatter.text(for: command)
        return RunAuthorizationScope(identity: identity, label: label, isExact: true)
    }

    /// Preserves the existing explicit broader prefix's literal identity and display label.
    static func prefix(_ value: String) -> RunAuthorizationScope {
        RunAuthorizationScope(
            identity: RunAuthorizationIdentity(prefix: value), label: value, isExact: false
        )
    }

    static func == (lhs: RunAuthorizationScope, rhs: RunAuthorizationScope) -> Bool {
        lhs.identity == rhs.identity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    private static func appendCount(_ count: Int, to data: inout Data) {
        var bigEndian = UInt64(count).bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
