import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder settings localization")
struct FolderLocalizationTests {
    @Test(arguments: ["en", "cs"])
    func capabilityFloorAndUnknownSupport(language: String) throws {
        let locale = Locale(identifier: language)
        let upgrade = try #require(FolderSettingsLocalization.capabilityMessage(.requiresUpgrade, locale: locale))
        #expect(upgrade.contains("2.5.0"))
        #expect(FolderSettingsLocalization.capabilityMessage(.checking, locale: locale) != nil)
        #expect(FolderSettingsLocalization.capabilityMessage(.unavailable, locale: locale) != nil)
        #expect(FolderSettingsLocalization.capabilityMessage(.supported, locale: locale) == nil)
        if language == "cs" { #expect(upgrade == "Složky vyžadují Pass CLI 2.5.0 nebo novější.") }
        else { #expect(upgrade == "Folders require Pass CLI 2.5.0 or newer.") }
    }

    @Test(arguments: [0, 1, 2, 5])
    func countsUseTheViewLocale(count: Int) {
        #expect(FolderSettingsLocalization.counts(selected: count, usable: count, locale: Locale(identifier: "en")) == "\(count) selected, \(count) usable")
        #expect(FolderSettingsLocalization.counts(selected: count, usable: count, locale: Locale(identifier: "cs")) == "Vybráno: \(count), použitelných: \(count)")
    }

    @Test(arguments: ["en", "cs"])
    func inheritedAndIndependentStatesPreserveExactUserPaths(language: String) {
        let literal = "Osobní / %{not-a-key} / Same — účty"
        let parent = row("parent", names: [literal], selected: true)
        let child = row("child", names: [literal, "Leaf"], selected: false, ancestor: "parent")
        let independent = row("child", names: [literal, "Leaf"], selected: true, ancestor: "parent")
        let locale = Locale(identifier: language)
        let inherited = FolderSettingsLocalization.policyDescription(child, rows: [parent, child], vaultSelected: false, locale: locale)
        let explicit = FolderSettingsLocalization.policyDescription(independent, rows: [parent, independent], vaultSelected: false, locale: locale)
        #expect(inherited == (language == "cs" ? "Zahrnuto složkou \(literal)" : "Included by \(literal)"))
        #expect(explicit == (language == "cs" ? "Vybráno samostatně; zahrnuto také složkou \(literal)" : "Selected independently; also included by \(literal)"))
        #expect(child.path == literal + " / Leaf")
        #expect(OfflineFolderTreeState.isInheritedOnly(child, vaultSelected: false))
        #expect(!OfflineFolderTreeState.isInheritedOnly(independent, vaultSelected: false))
    }

    @Test(arguments: ["en", "cs"])
    func itemContextKeepsIndependentAndBothCoveringPolicies(language: String) {
        let policy = OfflineItemPolicy(key: .init(vaultId: "vault", itemId: "item", schemaVersion: 1),
            isManuallySelected: true, vaultSelection: .init(vaultID: "vault", generation: UUID()), isExcluded: false,
            folderSelections: [.init(vaultID: "vault", folderID: "folder", generation: UUID())])
        let context = FolderSettingsLocalization.itemPolicyDescription(policy, locale: Locale(identifier: language))
        #expect(context == (language == "cs"
            ? "Vybráno samostatně · Zahrnuto vybraným trezorem · Zahrnuto vybranou složkou"
            : "Selected independently · Included by selected vault · Included by selected folder"))
        let path = "Osobní / %{not-a-key} / Same — účty"
        let label = FolderSettingsLocalization.text("Collapse folder \(path)", locale: Locale(identifier: language))
        #expect(label == (language == "cs" ? "Sbalit složku \(path)" : "Collapse folder \(path)"))
    }

    @Test(arguments: [0, 1, 2, 5])
    func pickerCountsUsePluralFormsAndViewLocale(count: Int) {
        let en = Locale(identifier: "en"), cs = Locale(identifier: "cs")
        #expect(FolderSettingsLocalization.folderSelections(count: count, locale: en)
            == "\(count) folder \(count == 1 ? "selection" : "selections")")
        let selected = count == 1 ? "Vybraná složka" : (2...4).contains(count) ? "Vybrané složky" : "Vybraných složek"
        #expect(FolderSettingsLocalization.folderSelections(count: count, locale: cs) == "\(selected): \(count)")
        #expect(FolderSettingsLocalization.foldersShown(count: count, locale: en)
            == "\(count) \(count == 1 ? "folder" : "folders") shown")
        let shown = count == 1 ? "Zobrazena \(count) složka" : (2...4).contains(count)
            ? "Zobrazeny \(count) složky" : "Zobrazeno \(count) složek"
        #expect(FolderSettingsLocalization.foldersShown(count: count, locale: cs) == shown)
    }

    @Test func pickerCopyAndVaultHintUseCzechWithoutLocalizingUserValues() {
        let locale = Locale(identifier: "cs")
        let resources: [(LocalizedStringResource, String)] = [
            ("Choose folders to keep offline", "Vyberte složky pro offline přístup"),
            ("Manage folders…", "Spravovat složky…"), ("Filter folders", "Filtrovat složky"),
            ("Selected only", "Pouze vybrané"), ("How offline access works", "Jak funguje offline přístup"),
            ("Vault", "Trezor"), ("This vault is no longer available.", "Tento trezor už není dostupný."),
            ("No matching folders.", "Žádné odpovídající složky."),
            ("No selected folders in this vault.", "V tomto trezoru nejsou vybrány žádné složky."),
            ("Choose whole vaults, folders, or individual items to keep offline.", "Pro offline přístup vyberte celé trezory, složky nebo jednotlivé položky."),
            ("Folder selection updated.", "Výběr složek byl aktualizován.")
        ]
        for (resource, expected) in resources {
            #expect(FolderSettingsLocalization.text(resource, locale: locale) == expected)
        }
        let vault = "Osobní / %{not-a-key} — Vault"
        #expect(FolderSettingsLocalization.text("Manage offline folders in \(vault)", locale: locale)
            == "Spravovat offline složky v trezoru \(vault)")
    }

    private func row(_ id: String, names: [String], selected: Bool, ancestor: String? = nil) -> OfflineFolderSettingsRow {
        .init(vaultID: "vault", folderID: id, folderName: names.last ?? "", location: .init(folderID: id, ancestorNames: names),
              isSelected: selected, coveringAncestorID: ancestor, selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
    }

    @Test func offlineItemStatusLabelsUseTheViewLocaleLanguage() {
        func label(_ status: OfflineCacheStatus, usable: Bool, _ language: String) -> String {
            let row = OfflineItemSettingsRow(
                itemId: "item", vaultId: "vault", title: "Offline example", itemType: .login,
                status: status, lastRefreshedAt: nil, hasUsableSnapshot: usable,
                item: offlineTestMetadata(id: "item", vaultID: "vault"))
            return OfflineItemsManagerView.statusLabel(for: row, locale: Locale(identifier: language))
        }
        #expect(label(.cached, usable: true, "en") == "Cached")
        #expect(label(.cached, usable: true, "cs") == "Uloženo")
        #expect(label(.failed, usable: true, "cs") == "Neaktuální")
        #expect(label(.notCached, usable: false, "cs") == "Nedostupné")
    }

}
