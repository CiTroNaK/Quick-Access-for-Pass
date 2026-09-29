import Foundation

nonisolated extension AutoFillCredentialDescriptor {
    /// Projects one transient CLI login into non-secret, per-domain descriptor inputs.
    static func inputs(
        from cliItem: CLIItem,
        metadata: PassItem,
        shareID: String
    ) -> [AutoFillDescriptorInput] {
        guard cliItem.state == "Active", case .login(let login) = cliItem.content.content else {
            return []
        }

        return inputs(for: AutoFillDescriptorMetadata(
            vaultID: metadata.vaultId,
            itemID: metadata.id,
            shareID: shareID,
            title: metadata.title,
            username: metadata.subtitle,
            urls: login.urls,
            hasTOTP: metadata.hasTOTP
        ))
    }
}
