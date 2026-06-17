extension QuickAccessViewModel {
    func vaultName(for vaultId: String) -> String {
        (try? searchService.vaultName(for: vaultId)) ?? ""
    }

    func shareId(for item: PassItem) -> String {
        guard let shareId = try? searchService.vaultShareId(for: item.vaultId), !shareId.isEmpty else {
            return item.vaultId
        }
        return shareId
    }
}
