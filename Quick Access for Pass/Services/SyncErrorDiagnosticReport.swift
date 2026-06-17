import Foundation

nonisolated enum SyncErrorDiagnosticReport {
    static let supportEmail = "yes@petr.codes"

    static func make(
        error: Error,
        cliSelection: PassCLISelection,
        operation: String = "fetchAllItems -> upsertVaults/syncItems/removeVaultsNotIn",
        skippedItems: [SkippedSyncItem] = [],
        diagnosticFileURL: URL? = nil,
        date: Date = Date(),
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let timestamp = timestampString(from: date)
        let rawDetails = errorDetails(from: error)
        let sanitizedDetails = sanitize(rawDetails)
        let skippedSection = skippedSection(skippedItems: skippedItems, diagnosticFileURL: diagnosticFileURL)

        return sanitize(
            """
            Quick Access for Pass Sync Diagnostic Report

            Review this report for anything sensitive before sending it.

            App: Quick Access for Pass
            Version: \(version) (\(build))
            macOS: \(processInfo.operatingSystemVersionString)
            Timestamp: \(timestamp)
            CLI source: \(cliSelection.sourceLabel)
            CLI path: \(cliSelection.path)
            Operation: \(operation)
            \(skippedSection)

            Error:
            \(sanitizedDetails)
            """
        )
    }

    static func mailtoURL() -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Quick Access for Pass sync error"),
            URLQueryItem(
                name: "body",
                value: """
                I hit a sync error in Quick Access for Pass.

                Diagnostic details were copied to my clipboard.
                Please review them for anything sensitive, then paste them below:
                """
            ),
        ]
        return components.url
    }

    static func sanitize(_ input: String) -> String {
        var output = input
        output = replace(
            pattern: #"https://account\.proton\.me/desktop/login[^\s\)\]\}"']+"#,
            in: output,
            with: "[Proton login URL redacted]"
        )
        output = replace(
            pattern: #"PROTON_PASS_PERSONAL_ACCESS_TOKEN\s*=\s*[^\s\n]+"#,
            in: output,
            with: "PROTON_PASS_PERSONAL_ACCESS_TOKEN=[redacted]"
        )
        output = replace(
            pattern: #"pst_[A-Za-z0-9_:\.\-]+"#,
            in: output,
            with: "[personal access token redacted]"
        )
        output = replace(
            pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            in: output,
            with: "[email redacted]"
        )
        output = replace(
            pattern: #"pass://[^\s\)\]\}"']+"#,
            in: output,
            with: "pass://[redacted]"
        )
        output = replace(
            pattern: #"/Users/[^/\s]+/"#,
            in: output,
            with: "~/"
        )
        return output
    }

    private static func skippedSection(skippedItems: [SkippedSyncItem], diagnosticFileURL: URL?) -> String {
        guard !skippedItems.isEmpty else { return "Skipped items: none" }
        let inlineSummaries = skippedItems.prefix(20).map(\.diagnosticSummary).joined(separator: "\n")
        let fileLine = diagnosticFileURL.map { "\nFull skipped-item diagnostics file: \($0.path)" } ?? ""
        return """
        Skipped items (showing first \(min(skippedItems.count, 20)) of \(skippedItems.count)):
        \(inlineSummaries)\(fileLine)
        """
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func errorDetails(from error: Error) -> String {
        switch error {
        case CLIError.notInstalled:
            "CLIError.notInstalled: \(error.localizedDescription)"
        case CLIError.notLoggedIn:
            "CLIError.notLoggedIn: \(error.localizedDescription)"
        case CLIError.commandFailed(let message):
            "CLIError.commandFailed:\n\(message)"
        case CLIError.timeout:
            "CLIError.timeout: \(error.localizedDescription)"
        case CLIError.parseError(let message):
            "CLIError.parseError:\n\(message)"
        default:
            "\(type(of: error)): \(error.localizedDescription)"
        }
    }

    private static func replace(pattern: String, in input: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }
}
