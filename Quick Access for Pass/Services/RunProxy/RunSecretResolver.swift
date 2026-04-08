import Foundation

nonisolated enum RunSecretResolver {
    static func resolve(
        mappings: [RunProfileEnvMapping],
        cliPath: String
    ) async throws -> [String: String] {
        let tempFile = NSTemporaryDirectory() + "qa-resolve-\(UUID().uuidString.prefix(8)).env"
        let envNames = Set(mappings.map(\.envVariable))
        let content = mappings
            .map { "\($0.envVariable)=\($0.secretReference)" }
            .joined(separator: "\n")
        try content.write(toFile: tempFile, atomically: true, encoding: .utf8)
        chmod(tempFile, 0o600)
        defer { unlink(tempFile) }

        let data = try await CLIRunner.run(
            executablePath: cliPath,
            arguments: ["run", "--env-file", tempFile, "--", "/usr/bin/env"],
            timeout: 30
        )

        guard let output = String(data: data, encoding: .utf8) else { return [:] }
        return parseEnvOutput(output, keys: envNames)
    }

    /// Parse `/usr/bin/env`-style output into a `[String: String]`,
    /// filtered to include only keys present in `keys`. Handles values
    /// that contain `=` by splitting on the first occurrence only.
    /// Lines without any `=` are skipped silently. Empty values are
    /// preserved as empty strings.
    ///
    /// Extracted from `resolve(...)` for unit testing. `resolve` calls
    /// this with the stdout of `pass-cli run -- /usr/bin/env`, which
    /// emits one `KEY=VALUE` line per environment variable.
    static func parseEnvOutput(_ output: String, keys: Set<String>) -> [String: String] {
        var resolved: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIdx])
            let value = String(line[line.index(after: eqIdx)...])
            if keys.contains(key) {
                resolved[key] = value
            }
        }
        return resolved
    }
}
