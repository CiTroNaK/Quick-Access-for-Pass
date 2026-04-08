import Foundation
import os

nonisolated enum CLIError: Error, LocalizedError {
    case notInstalled
    case notLoggedIn
    case commandFailed(String)
    case timeout
    case parseError(String)

    var isNotInstalled: Bool {
        if case .notInstalled = self { return true }
        return false
    }

    var isAuthError: Bool {
        switch self {
        case .notLoggedIn: true
        case .commandFailed(let msg): CLIRunner.stderrIndicatesNotLoggedIn(msg)
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "pass-cli is not installed. Instructionas at https://protonpass.github.io/pass-cli/")
        case .notLoggedIn: String(localized: "Not logged in to Proton Pass. Please run: pass-cli login")
        case .commandFailed(let msg): String(localized: "pass-cli command failed: \(msg)")
        case .timeout: String(localized: "pass-cli command timed out")
        case .parseError(let msg): String(localized: "Failed to parse pass-cli output: \(msg)")
        }
    }
}

actor PassCLIService {
    private nonisolated let pathStore: OSAllocatedUnfairLock<String>
    private let timeoutSeconds: Double = 300

    nonisolated var cliPath: String {
        pathStore.withLock { $0 }
    }

    nonisolated func updateCLIPath(_ path: String) {
        pathStore.withLock { $0 = path }
    }

    init(cliPath: String? = nil) {
        let resolved = cliPath ?? Self.findCLIPath() ?? "pass-cli"
        self.pathStore = OSAllocatedUnfairLock(initialState: resolved)
    }

    // MARK: - CLI Path Discovery

    static func findCLIPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/pass-cli",
            "/usr/local/bin/pass-cli",
            NSString("~/.local/bin/pass-cli").expandingTildeInPath,
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["pass-cli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty {
            return output
        }
        return nil
    }

    // MARK: - Commands

    func listVaults() async throws -> [CLIVault] {
        let data = try await run(arguments: ["vault", "list", "--output", "json"])
        return try Self.parseVaultList(from: data)
    }

    func listItems(shareId: String) async throws -> [CLIItem] {
        let data = try await run(arguments: ["item", "list", "--share-id=\(shareId)", "--output", "json"])
        return try Self.parseItemList(from: data)
    }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        let uri = "pass://\(shareId)/\(itemId)"
        let data = try await run(arguments: ["item", "view", "--output", "json", uri])
        let response = try JSONDecoder().decode(CLIItemViewResponse.self, from: data)
        return response.item
    }

    func getTotp(itemId: String, shareId: String) async throws -> String {
        let uri = "pass://\(shareId)/\(itemId)"
        let data = try await run(arguments: ["item", "totp", "--output", "json", uri])
        return try Self.parseTotp(from: data)
    }

    func fetchAllItems() async throws -> (vaults: [CLIVault], items: [(item: CLIItem, vaultId: String)]) {
        let vaults = try await listVaults()
        let allItems = try await withThrowingTaskGroup(of: [(item: CLIItem, vaultId: String)].self) { group in
            for vault in vaults {
                group.addTask {
                    let items = try await self.listItems(shareId: vault.shareId)
                    return items.map { (item: $0, vaultId: vault.shareId) }
                }
            }
            var result: [(item: CLIItem, vaultId: String)] = []
            for try await batch in group {
                result.append(contentsOf: batch)
            }
            return result
        }
        return (vaults, allItems)
    }

    // MARK: - Process Execution

    private func run(arguments: [String]) async throws -> Data {
        try await CLIRunner.run(executablePath: cliPath, arguments: arguments, timeout: timeoutSeconds)
    }

    // MARK: - Parsing (static for testing)

    static func parseVaultList(from data: Data) throws -> [CLIVault] {
        do {
            return try JSONDecoder().decode(CLIVaultListResponse.self, from: data).vaults
        } catch {
            throw CLIError.parseError(error.localizedDescription)
        }
    }

    static func parseItemList(from data: Data) throws -> [CLIItem] {
        do {
            return try JSONDecoder().decode(CLIItemListResponse.self, from: data).items
        } catch {
            throw CLIError.parseError(error.localizedDescription)
        }
    }

    static func parseTotp(from data: Data) throws -> String {
        do {
            return try JSONDecoder().decode(CLITotpResponse.self, from: data).totp
        } catch {
            throw CLIError.parseError(error.localizedDescription)
        }
    }
}
