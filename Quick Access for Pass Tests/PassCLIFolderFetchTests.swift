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
    private var commands: [(String, [String])] = []
    private var bounds: [Int] = []

    init(version: String = "2.5.1", mode: String = "complete", folderGate: IncrementalSyncGate? = nil) {
        self.version = version
        self.mode = mode
        self.folderGate = folderGate
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        bounds.append(maximumOutputBytes)
        return try await run(executablePath: executablePath, arguments: arguments, timeout: timeout)
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        commands.append((executablePath, arguments))
        switch arguments.first {
        case "--version": return Data(version.utf8)
        case "vault": return Data("{\"vaults\":[{\"name\":\"Synthetic vault\",\"vault_id\":\"vault\",\"share_id\":\"share\"}]}".utf8)
        case "item": return try FolderCLIContractFixture.itemData(folderValue: "child", includeState: mode != "missing-membership")
        case "folder":
            await folderGate?.wait()
            if mode == "failure" { throw CLIError.timeout }
            if mode == "malformed" { return Data("{}".utf8) }
            return try FolderCLIContractFixture.folders([("child", nil, "Synthetic folder")])
        default: throw CLIError.commandFailed("Unexpected synthetic command")
        }
    }

    func folderCommands() -> [[String]] { commands.filter { $0.1.first == "folder" }.map(\.1) }
    func folderExecutables() -> [String] { commands.filter { $0.1.first == "folder" }.map(\.0) }
    func itemListCount() -> Int { commands.filter { $0.1.first == "item" }.count }
    func outputBounds() -> [Int] { bounds }
}
