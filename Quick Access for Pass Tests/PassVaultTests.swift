import Testing
@testable import Quick_Access_for_Pass

@Suite("PassVault Tests")
struct PassVaultTests {
    @Test("uses stable vault id as database identity and keeps current share id")
    func stableIdentityAndCurrentShareId() {
        let cliVault = CLIVault(name: "Personal", vaultId: "stable-vault-id", shareId: "current-share-id")
        let vault = PassVault(from: cliVault)

        #expect(vault.id == "stable-vault-id")
        #expect(vault.shareId == "current-share-id")
        #expect(vault.name == "Personal")
    }
}
