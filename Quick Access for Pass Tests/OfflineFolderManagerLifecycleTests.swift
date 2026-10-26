import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder presentation lifetime versus service-owned work", .timeLimit(.minutes(1)))
@MainActor
struct OfflineFolderManagerLifecycleTests {
    @Test(arguments: [false, true])
    func disappearanceOrVaultSwitchCannotCancelSubmittedWork(switchVault: Bool) async throws {
        let gate = OfflineTestGate()
        let fixture = try await OfflineFolderManagerFixture(beforeView: { try await gate.wait() })
        do {
            var presentation = OfflineFolderManagerState(initialVaultID: "vault")
            presentation.setVisible(true)
            let submittedFeedback = presentation.beginFeedback(forVaultID: "vault")
            let token = try #require(submittedFeedback)
            try await fixture.coordinator.setFolderSelected(true, folderID: "child", vaultID: "vault")
            try await gate.waitUntilEntered()
            #expect(await fixture.viewCallCount("item") == 1)
            #expect(try await fixture.folders.snapshot() == nil)
            if switchVault { presentation.selectVault("another-vault") }
            else { presentation.setVisible(false) }
            #expect(!presentation.isFeedbackCurrent(token, vaultID: "vault"))
            await gate.open()
            await fixture.service.waitUntilIdle()
            #expect(try await fixture.folders.snapshot() != nil)
            let policyVaults = try await fixture.folders.database.reader.read {
                try String.fetchAll($0, sql: "SELECT vaultId FROM offlineFolders WHERE folderId = ? ORDER BY vaultId", arguments: ["child"])
            }
            #expect(policyVaults == ["vault"])
            #expect(await fixture.viewCallCount("other-item") == 0)
            #expect(!presentation.isFeedbackCurrent(token, vaultID: "vault"))
        } catch {
            await gate.open()
            await fixture.service.stop()
            throw error
        }
        await fixture.service.stop()
    }
}
