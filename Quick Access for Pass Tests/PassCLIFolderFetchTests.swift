import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Invocation-bound folder fetch", .timeLimit(.minutes(1)))
struct PassCLIFolderFetchTests {
    @Test("unsupported and unknown versions execute no folder command", arguments: ["2.4.2", "garbage"])
    func unsupported(raw: String) async throws {
        let runner = FolderFetchRunner(version: raw)
        let service = PassCLIService(cliPath: "/fake/pass", runner: runner)
        let stamp = await service.prepareFolderSync()
        let result = try await service.fetchAllItems(folderFeatureStamp: stamp)
        guard case .unsupported = result.folderCatalogsByVaultID["vault"] else {
            Issue.record("Unsupported capability became folder evidence")
            return
        }
        #expect(await runner.folderCommands().isEmpty)
        #expect(result.items.count == 1)
    }

    @Test("one bounded folder command reuses list membership without another secret fetch")
    func supported() async throws {
        let runner = FolderFetchRunner()
        let service = PassCLIService(cliPath: "/fake/pass", runner: runner)
        let stamp = try #require(await service.prepareFolderSync())
        let result = try await service.fetchAllItems(folderFeatureStamp: stamp)
        guard case .complete(let catalog) = result.folderCatalogsByVaultID["vault"] else {
            Issue.record("Missing complete folder evidence")
            return
        }
        #expect(catalog.stamp == stamp)
        #expect(catalog.itemMemberships == ["item": .folder("child")])
        #expect(await runner.folderCommands() == [["folder", "list", "--share-id=share", "--output", "json"]])
        #expect(await runner.itemListCount() == 1)
        #expect(await runner.outputBounds() == [FolderCatalogLimits.maximumOutputBytes])
    }

    @Test("folder lists run a few vaults at a time with a metadata timeout")
    func boundedConcurrentFolderLists() async throws {
        let runner = FolderFetchRunner(vaultCount: 6)
        let service = PassCLIService(cliPath: "/fake/pass", runner: runner)
        let stamp = try #require(await service.prepareFolderSync())
        let result = try await service.fetchAllItems(folderFeatureStamp: stamp)
        #expect(result.folderCatalogsByVaultID.count == 6)
        #expect(result.folderCatalogsByVaultID.values.allSatisfy { if case .complete = $0 { true } else { false } })
        let maximum = await runner.maximumConcurrentFolderLists()
        #expect(maximum > 1 && maximum <= 4)
        #expect(await runner.folderTimeouts().allSatisfy { $0 == 60 })
    }

    @Test("folder failures do not fail ordinary item sync", arguments: ["failure", "malformed", "missing-membership"])
    func optionalFailure(mode: String) async throws {
        let runner = FolderFetchRunner(mode: mode)
        let service = PassCLIService(cliPath: "/fake/pass", runner: runner)
        let stamp = try #require(await service.prepareFolderSync())
        let result = try await service.fetchAllItems(folderFeatureStamp: stamp)
        #expect(result.items.count == 1)
        guard case .unavailable = result.folderCatalogsByVaultID["vault"] else {
            Issue.record("Incomplete evidence became authoritative")
            return
        }
    }

    @Test("stale selection rejects awaited folder data from the captured executable")
    func staleSelection() async throws {
        let barrier = IncrementalSyncGate()
        let runner = FolderFetchRunner(folderGate: barrier)
        let service = PassCLIService(cliPath: "/fake/pass", runner: runner)
        let stamp = try #require(await service.prepareFolderSync())
        let fetch = Task { try await service.fetchAllItems(folderFeatureStamp: stamp) }
        await barrier.waitUntilEntered()
        service.updateCLIPath("/fake/replacement")
        await barrier.open()
        let result = try await fetch.value
        guard case .unavailable = result.folderCatalogsByVaultID["vault"] else {
            Issue.record("Old selection admitted folder evidence")
            return
        }
        #expect(await runner.folderExecutables() == ["/fake/pass"])
    }

    @Test("support discovered after admission cannot retroactively enable folder discovery")
    func noRetroactiveAdmission() async throws {
        let runner = FolderFetchRunner()
        let service = PassCLIService(cliPath: "/fake/pass", runner: runner)
        _ = await service.prepareFolderSync()
        _ = try await service.fetchAllItems(folderFeatureStamp: nil)
        #expect(await runner.folderCommands().isEmpty)
    }
}

private actor FolderFetchRunner: CLIRunning {
    let version: String
    let mode: String
    let folderGate: IncrementalSyncGate?
    let vaultCount: Int
    private var commands: [(String, [String])] = []
    private var bounds: [Int] = []
    private var timeouts: [TimeInterval] = []
    private var activeFolderLists = 0
    private var maximumFolderLists = 0

    init(version: String = "2.5.1", mode: String = "complete", folderGate: IncrementalSyncGate? = nil, vaultCount: Int = 1) {
        self.version = version
        self.mode = mode
        self.folderGate = folderGate
        self.vaultCount = vaultCount
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        bounds.append(maximumOutputBytes)
        return try await run(executablePath: executablePath, arguments: arguments, timeout: timeout)
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        commands.append((executablePath, arguments))
        switch arguments.first {
        case "--version": return Data(version.utf8)
        case "vault":
            guard vaultCount > 1 else {
                return Data("{\"vaults\":[{\"name\":\"Synthetic vault\",\"vault_id\":\"vault\",\"share_id\":\"share\"}]}".utf8)
            }
            let vaults = (1...vaultCount).map { "{\"name\":\"Vault \($0)\",\"vault_id\":\"vault-\($0)\",\"share_id\":\"share-\($0)\"}" }
            return Data("{\"vaults\":[\(vaults.joined(separator: ","))]}".utf8)
        case "item":
            let shareID = Self.shareID(in: arguments)
            return try FolderCLIContractFixture.itemData(folderValue: "child", includeState: mode != "missing-membership",
                                                         shareID: shareID, vaultID: shareID.replacingOccurrences(of: "share", with: "vault"))
        case "folder":
            timeouts.append(timeout)
            activeFolderLists += 1
            maximumFolderLists = max(maximumFolderLists, activeFolderLists)
            defer { activeFolderLists -= 1 }
            if vaultCount > 1 { try await Task.sleep(for: .milliseconds(20)) }
            await folderGate?.wait()
            if mode == "failure" { throw CLIError.timeout }
            if mode == "malformed" { return Data("{}".utf8) }
            return try FolderCLIContractFixture.folders([("child", nil, "Synthetic folder")], shareID: Self.shareID(in: arguments))
        default: throw CLIError.commandFailed("Unexpected synthetic command")
        }
    }

    func folderCommands() -> [[String]] { commands.filter { $0.1.first == "folder" }.map(\.1) }
    func folderExecutables() -> [String] { commands.filter { $0.1.first == "folder" }.map(\.0) }
    func itemListCount() -> Int { commands.filter { $0.1.first == "item" }.count }
    func outputBounds() -> [Int] { bounds }
    func folderTimeouts() -> [TimeInterval] { timeouts }
    private static func shareID(in arguments: [String]) -> String {
        arguments.first { $0.hasPrefix("--share-id=") }.map { String($0.dropFirst("--share-id=".count)) } ?? "share"
    }
    func maximumConcurrentFolderLists() -> Int { maximumFolderLists }
}
