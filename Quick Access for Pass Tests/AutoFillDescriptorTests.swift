import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill credential descriptor derivation")
struct AutoFillDescriptorTests {
    @Test("derives distinct normalized web domains from every transient login URL")
    func derivesAllLoginDomains() throws {
        let cliItem = try makeCLIItem(
            state: "Active",
            urls: [
                "https://Login.Example.com/path?q=1",
                "http://login.example.com/other",
                "https://accounts.example.org/login",
                "https://münich.example/sign-in",
                "ftp://files.example.net/secret",
                "not a URL",
                "https:///missing-host"
            ],
            password: "database-must-not-contain-this-password",
            totpURI: "otpauth://totp/example?secret=DATABASEMUSTNOTCONTAINTHISSEED"
        )
        let item = PassItem(from: cliItem, vaultId: "vault-id")

        let inputs = AutoFillCredentialDescriptor.inputs(
            from: cliItem,
            metadata: item,
            shareID: "current-share-id"
        )

        #expect(inputs.map(\.serviceIdentifier) == [
            "accounts.example.org", "login.example.com", "xn--mnich-kva.example"
        ])
        #expect(inputs.allSatisfy { $0.vaultID == "vault-id" && $0.itemID == "item-id" })
        #expect(inputs.allSatisfy { $0.shareID == "current-share-id" })
        #expect(inputs.allSatisfy { $0.username == "person@example.com" })
        #expect(inputs.allSatisfy { $0.hasTOTP })

        let encoded = String(decoding: try JSONEncoder().encode(inputs), as: UTF8.self)
        #expect(!encoded.contains("database-must-not-contain-this-password"))
        #expect(!encoded.contains("DATABASEMUSTNOTCONTAINTHISSEED"))
        #expect(!encoded.contains("otpauth"))
    }

    @Test("metadata descriptor inputs retain normalized non-secret domains")
    func metadataDescriptorInputsRetainNormalizedDomains() {
        let metadata = AutoFillDescriptorMetadata(
            vaultID: "vault-id",
            itemID: "item-id",
            shareID: "share-id",
            title: "Example",
            username: "user@example.com",
            urls: ["https://example.com/login", "https://EXAMPLE.com/second"],
            hasTOTP: false
        )

        #expect(AutoFillCredentialDescriptor.inputs(for: metadata) == [
            AutoFillDescriptorInput(
                vaultID: "vault-id",
                itemID: "item-id",
                shareID: "share-id",
                title: "Example",
                username: "user@example.com",
                serviceIdentifier: "example.com",
                hasTOTP: false
            )
        ])
    }

    @Test("derives descriptors only for active login items")
    func activeLoginsOnly() throws {
        let trashedLogin = try makeCLIItem(state: "Trashed", urls: ["https://example.com"])
        let trashedMetadata = PassItem(from: trashedLogin, vaultId: "vault-id")
        #expect(AutoFillCredentialDescriptor.inputs(
            from: trashedLogin,
            metadata: trashedMetadata,
            shareID: "share-id"
        ).isEmpty)

        let note = try makeCLIItem(state: "Active", content: ["Note": NSNull()])
        let noteMetadata = PassItem(from: note, vaultId: "vault-id")
        #expect(AutoFillCredentialDescriptor.inputs(
            from: note,
            metadata: noteMetadata,
            shareID: "share-id"
        ).isEmpty)
    }

    private func makeCLIItem(
        state: String,
        urls: [String] = [],
        password: String = "password",
        totpURI: String = "",
        content: [String: Any]? = nil
    ) throws -> CLIItem {
        let typedContent = content ?? [
            "Login": [
                "email": "fallback@example.com",
                "username": "person@example.com",
                "password": password,
                "urls": urls,
                "totp_uri": totpURI,
                "passkeys": []
            ]
        ]
        let object: [String: Any] = [
            "id": "item-id",
            "share_id": "cli-share-id",
            "vault_id": "vault-id",
            "state": state,
            "flags": [],
            "create_time": "2026-09-24T12:00:00Z",
            "modify_time": "2026-09-24T12:00:00Z",
            "content": [
                "title": "Example Login",
                "note": "",
                "item_uuid": "item-id",
                "content": typedContent,
                "extra_fields": []
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(CLIItem.self, from: data)
    }
}
