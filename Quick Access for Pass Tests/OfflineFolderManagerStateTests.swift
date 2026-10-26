import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Request-scoped offline folder manager presentation")
struct OfflineFolderManagerStateTests {
    @Test func switchingVaultsClearsFiltersAndDisclosureWithoutRetargetingSilently() {
        var state = OfflineFolderManagerState(initialVaultID: "a")
        state.query = "Literal / %{not-a-key}"
        state.selectedOnly = true
        state.tree.toggleExpansion(.init(vaultID: "a", folderID: "parent"))
        state.selectVault("b")
        #expect(state.selectedVaultID == "b")
        #expect(state.query.isEmpty)
        #expect(!state.selectedOnly)
        #expect(state.tree.collapsed.isEmpty)
        #expect(state.selectedVault(in: [vault("a"), vault("b")])?.id == "b")
    }

    @Test func liveRenameCoverageAndCommittedRowsUseStableIdentityNotDuplicateNames() {
        var state = OfflineFolderManagerState(initialVaultID: "a")
        state.selectedOnly = true
        let a = vault("a")
        let original = row(vaultID: "a", folderID: "child", name: "Old", selected: false)
        #expect(state.visibleRows(vaults: [a], rowsByVaultID: ["a": [original]], availability: .supported).isEmpty)
        let literal = "Same / %{not-a-key} — účty"
        let renamed = OfflineVaultSettingsRow(id: "a", vaultName: literal, isSelected: true,
            selectedCount: 1, usableCount: 1, lastRefreshedAt: nil)
        let duplicate = OfflineVaultSettingsRow(id: "b", vaultName: literal, isSelected: false,
            selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
        let changed = row(vaultID: "a", folderID: "child", name: literal, selected: false)
        let other = row(vaultID: "b", folderID: "child", name: "Wrong vault", selected: true)
        let current = state.selectedVault(in: [duplicate, renamed])
        #expect(current?.id == "a")
        #expect(current?.vaultName == literal)
        #expect(current?.isSelected == true)
        let visible = state.visibleRows(vaults: [duplicate, renamed], rowsByVaultID: ["a": [changed], "b": [other]], availability: .supported)
        #expect(visible.map(\.id) == [changed.id])
        #expect(visible.first?.path == literal)
        #expect(visible.first?.isSelected == false) // inherited whole-vault coverage never promotes intent
    }

    @Test func missingVaultNeverFallsBackToAnotherLiveVault() {
        let state = OfflineFolderManagerState(initialVaultID: "a")
        let rows = [row(vaultID: "b", folderID: "child", name: "Other", selected: true)]
        #expect(state.selectedVault(in: [vault("b")]) == nil)
        #expect(state.visibleRows(vaults: [vault("b")], rowsByVaultID: ["b": rows], availability: .supported).isEmpty)
        #expect(state.selectedVaultID == "a")
        #expect(state.selectedVault(in: [vault("a")])?.id == "a")
    }

    @Test func downgradeKeepsEveryExplicitPolicyRemovableDespiteOldFilters() {
        var state = OfflineFolderManagerState(initialVaultID: "a")
        state.query = "no match"
        state.selectedOnly = true
        let parent = row(vaultID: "a", folderID: "parent", name: "Parent", selected: false)
        state.tree.toggleExpansion(parent.id)
        let selected = row(vaultID: "a", folderID: "child", name: "Literal / child", selected: true)
        #expect(state.visibleRows(vaults: [vault("a")], rowsByVaultID: ["a": [parent, selected]],
                                  availability: .requiresUpgrade).map(\.id) == [selected.id])
        state.updateAvailability(.unavailable)
        #expect(state.query.isEmpty)
        #expect(!state.selectedOnly)
    }

    @Test func feedbackCannotSurviveNewerRequestVaultRoundTripOrDisappearance() throws {
        var state = OfflineFolderManagerState(initialVaultID: "a")
        state.setVisible(true)
        let oldRequest = state.beginFeedback(forVaultID: "a")
        let old = try #require(oldRequest)
        let currentRequest = state.beginFeedback(forVaultID: "a")
        let current = try #require(currentRequest)
        #expect(!state.isFeedbackCurrent(old, vaultID: "a"))
        #expect(state.isFeedbackCurrent(current, vaultID: "a"))
        let wrongVaultRequest = state.beginFeedback(forVaultID: "b")
        #expect(wrongVaultRequest == nil)
        state.selectVault("b")
        state.selectVault("a")
        #expect(!state.isFeedbackCurrent(current, vaultID: "a"))
        let hiddenRequest = state.beginFeedback(forVaultID: "a")
        let hidden = try #require(hiddenRequest)
        state.setVisible(false)
        #expect(!state.isFeedbackCurrent(hidden, vaultID: "a"))
        state.setVisible(true)
        #expect(!state.isFeedbackCurrent(hidden, vaultID: "a"))
        let downgradedRequest = state.beginFeedback(forVaultID: "a")
        let downgraded = try #require(downgradedRequest)
        state.updateAvailability(.unavailable)
        #expect(!state.isFeedbackCurrent(downgraded, vaultID: "a"))
    }

    private func vault(_ id: String) -> OfflineVaultSettingsRow {
        .init(id: id, vaultName: "Literal / %{vault} \(id)", isSelected: false,
              selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
    }

    private func row(vaultID: String, folderID: String, name: String, selected: Bool) -> OfflineFolderSettingsRow {
        .init(vaultID: vaultID, folderID: folderID, folderName: name,
              location: .init(folderID: folderID, ancestorNames: [name]), isSelected: selected,
              coveringAncestorID: nil, selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
    }
}
