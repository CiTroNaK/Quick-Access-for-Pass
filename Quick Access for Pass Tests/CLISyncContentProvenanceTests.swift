import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("CLI sync content provenance", .timeLimit(.minutes(1)))
struct CLISyncContentProvenanceTests {
    @Test("sync list pins the executable across capability suspension")
    func syncListPinsExecutable() async throws {
        let gate = OfflineTestGate()
        let runner = SyncContentRunner(versionGate: gate)
        let service = PassCLIService(cliPath: "/synthetic/original", runner: runner)
        let vault = try JSONDecoder().decode(CLIVault.self, from: Data(
            #"{"name":"Vault","vault_id":"vault","share_id":"share"}"#.utf8
        ))
        let task = Task { try await service.listItemsForSync(vault: vault) }
        try await gate.waitUntilEntered()
        service.updateCLIPath("/synthetic/replacement")
        await gate.open()
        _ = try await task.value
        #expect(await runner.listPaths() == ["/synthetic/original"])
    }

    @Test("decoding alone never establishes full content")
    func decodingDoesNotEstablishProvenance() throws {
        #expect(try parse(Self.completeNote).contentProvenance == .unavailable)
        #expect(try parse(Self.completeNote, provenance: .completeJSONV1).contentProvenance == .completeJSONV1)
    }

    @Test("missing defaulted content fields retain metadata but lose completeness")
    func missingFieldsAreNotFullSnapshots() throws {
        let data = Data(Self.completeNote.replacingOccurrences(of: #""note":"","# , with: "").utf8)
        let result = try CLIItemListLossyParser.parse(
            data, vaultId: "vault", vaultName: "Vault", shareId: "share", contentProvenance: .completeJSONV1
        )
        #expect(result.items.count == 1)
        #expect(result.skippedItems.isEmpty)
        #expect(result.contentProvenance == .unavailable)
    }

    @Test("exact releases are verified; other 2.5.0+ releases need agreement evidence", arguments: [
        ("2.1.4", "verified"), ("2.2.3", "verified"), ("2.3.3", "verified"), ("2.4.2", "verified"),
        ("2.5.1", "verified"), ("2.7.0", "verified"),
        ("Proton Pass CLI 2.1.4 (d13561a)", "verified"), ("Proton Pass CLI 2.2.3 (38ff599)", "verified"),
        ("Proton Pass CLI 2.3.3 (0d7235d)", "verified"), ("Proton Pass CLI 2.5.1 (84186e7)", "verified"),
        ("Proton Pass CLI 2.7.0 (ba80a19)", "verified"),
        ("2.1.3", "none"), ("2.1.5", "none"), ("2.2.2", "none"), ("2.2.4", "none"),
        ("2.3.2", "none"), ("2.3.4", "none"), ("2.4.1", "none"), ("2.4.3", "none"), ("unknown", "none"),
        ("2.5.0", "unverified"), ("2.5.2", "unverified"), ("2.6.0", "unverified"), ("2.7.1", "unverified"),
        ("Proton Pass CLI 2.8.0 (abcdef0)", "unverified"), ("3.0.0", "unverified")
    ])
    func releaseContract(version: String, expected: String) {
        let provenance = PassCLICapabilities(rawVersionString: version).snapshotContentProvenance
        switch expected {
        case "verified": #expect(provenance == .completeJSONV1)
        case "unverified": #expect(provenance == .unverifiedCompleteJSON)
        default: #expect(provenance == .unavailable)
        }
    }

    @Test("each supported modeled content shape is eligible, including empty values", arguments: [
        "Login", "Note", "Alias", "CreditCard", "Identity", "SshKey", "Wifi", "Custom"
    ])
    func supportedShapes(type: String) throws {
        let raw = Self.completeNote.replacingOccurrences(
            of: #""Note":null"#, with: type == "Note" ? #""Note":null"# : "\"\(type)\":{}"
        )
        let item = try #require(try PassCLIService.parseItemList(from: Data(raw.utf8)).first)
        let encoded = try JSONEncoder().encode(CLIItemListResponse(items: [item]))
        let result = try CLIItemListLossyParser.parse(
            encoded, vaultId: "vault", vaultName: "Vault", shareId: "share", contentProvenance: .completeJSONV1
        )
        #expect(result.contentProvenance == .completeJSONV1)
    }

    @Test("literal asterisks are legitimate content, not a redaction heuristic")
    func literalAsterisksAreValid() throws {
        let raw = Self.completeNote.replacingOccurrences(of: #""Note":null"#, with: #""Login":{"password":"***"}"#)
        let item = try #require(try PassCLIService.parseItemList(from: Data(raw.utf8)).first)
        let encoded = try JSONEncoder().encode(CLIItemListResponse(items: [item]))
        let result = try CLIItemListLossyParser.parse(
            encoded, vaultId: "vault", vaultName: "Vault", shareId: "share", contentProvenance: .completeJSONV1
        )
        #expect(result.contentProvenance == .completeJSONV1)
    }

    @Test("each actual vault invocation retains its own completeness", arguments: ["2.1.4", "2.2.3", "2.3.3", "2.4.2", "2.5.1", "2.7.0"])
    func independentVaultProvenance(version: String) async throws {
        let incomplete = Self.completeNote.replacingOccurrences(of: #""note":"","#, with: "")
            .replacingOccurrences(of: #""vault_id":"vault""#, with: #""vault_id":"second-vault""#)
            .replacingOccurrences(of: #""share_id":"share""#, with: #""share_id":"second-share""#)
        let runner = ProvenanceListRunner(version: version, lists: [
            "share": Data(Self.completeNote.utf8), "second-share": Data(incomplete.utf8)
        ])
        let result = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).fetchAllItems()
        #expect(result.items.count == 2)
        #expect(result.contentProvenanceByVaultID["vault"] == .completeJSONV1)
        #expect(result.contentProvenanceByVaultID["second-vault"] == .unavailable)
    }

    @Test("full-list alias email survives snapshot serialization", arguments: ["2.4.2", "2.5.1", "2.7.0"])
    func aliasEmailRetainsCompleteProvenance(version: String) async throws {
        let json = Self.completeNote
            .replacingOccurrences(of: #""Note":null"#, with: #""Alias":null"#)
            .replacingOccurrences(of: #""id":"item""#, with: #""id":"item","alias_email":"synthetic@example.com""#)
        let runner = ProvenanceListRunner(version: version, lists: [
            "share": Data(json.utf8), "second-share": Data(#"{"items":[]}"#.utf8)
        ])
        let result = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).fetchAllItems()
        #expect(result.contentProvenanceByVaultID["vault"] == .completeJSONV1)
        let entry = try #require(result.items.first)
        let data = try JSONEncoder().encode(entry.item)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["alias_email"] as? String == "synthetic@example.com")
    }

    @Test("older full-list login shape preserves modeled secrets without newer fields", arguments: ["2.1.4", "2.2.3", "2.3.3"])
    func olderLoginShapePreservesContent(version: String) async throws {
        // Synthetic values matching the older releases' derived ItemData/LoginItem JSON.
        // Deliberately no newer custom_icon, alias_email or autofill_urls fields.
        let json = Self.completeNote.replacingOccurrences(
            of: #""Note":null"#,
            with: #"""
            "Login":{"email":"synthetic@example.com","username":"uživatel","password":"synthetic-***",
            "urls":["https://example.com"],"totp_uri":"otpauth://totp/Synthetic?secret=JBSWY3DPEHPK3PXP","passkeys":[]}
            """#
        )
        let runner = ProvenanceListRunner(version: version, lists: [
            "share": Data(json.utf8), "second-share": Data(#"{"items":[]}"#.utf8)
        ])
        let result = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).fetchAllItems()
        #expect(result.contentProvenanceByVaultID["vault"] == .completeJSONV1)
        let entry = try #require(result.items.first)
        guard case .login(let login) = entry.item.content.content else {
            Issue.record("Expected synthetic login content")
            return
        }
        #expect(login.email == "synthetic@example.com")
        #expect(login.username == "uživatel")
        #expect(login.password == "synthetic-***")
        #expect(login.urls == ["https://example.com"])
        #expect(login.totpUri == "otpauth://totp/Synthetic?secret=JBSWY3DPEHPK3PXP")
    }

    @Test("summary and pre-2.5 unlisted invocations cannot acquire provenance", arguments: [
        "1.4.0", "unknown", "2.1.3", "2.1.5", "2.2.2", "2.2.4", "2.3.2", "2.3.4", "2.4.3"
    ])
    func unverifiedInvocations(version: String) async throws {
        let runner = ProvenanceListRunner(version: version, lists: [
            "share": Data(Self.completeNote.utf8), "second-share": Data(#"{"items":[]}"#.utf8)
        ])
        let result = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).fetchAllItems()
        #expect(result.contentProvenanceByVaultID.values.allSatisfy { $0 == .unavailable })
    }

    @Test("2.7.0 public top-level folders enrichment keeps full-list provenance")
    func topLevelFoldersKeyIsIgnored() async throws {
        let json = Self.completeNote.replacingOccurrences(of: "}]}", with: #"}],"folders":[{"folder_id":"f","folder_name":"Synthetic","parent_id":null}]}"#)
        let runner = ProvenanceListRunner(version: "2.7.0", lists: [
            "share": Data(json.utf8), "second-share": Data(#"{"items":[],"folders":[]}"#.utf8)
        ])
        let result = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).fetchAllItems()
        #expect(result.items.count == 1)
        #expect(result.contentProvenanceByVaultID["vault"] == .completeJSONV1)
    }

    @Test("a policy-restricted vault is isolated and retains its existing items")
    func sensitiveContentPolicyIsolatesVault() async throws {
        let runner = ProvenanceListRunner(version: "2.7.0", lists: ["share": Data(Self.completeNote.utf8)],
            failures: ["second-share": "Error: Viewing the contents of this item is not allowed by policy"])
        let result = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).fetchAllItems()
        #expect(result.items.map(\.item.id) == ["item"])
        #expect(result.restrictedVaultIDs == ["second-vault"])
        #expect(result.contentProvenanceByVaultID["second-vault"] == .unavailable)
        let uncertainty = try #require(result.presenceUncertainties.first { $0.vaultID == "second-vault" })
        #expect(uncertainty.hasUnidentifiedSkippedItems)
    }

    @Test("other list failures still fail the whole sync")
    func unrelatedListFailureStillThrows() async {
        let runner = ProvenanceListRunner(version: "2.7.0", lists: ["share": Data(Self.completeNote.utf8)],
            failures: ["second-share": "Error: network unreachable"])
        await #expect(throws: CLIError.self) {
            _ = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).fetchAllItems()
        }
    }

    @Test("a policy refusal on item view is reported as a restriction, not a generic failure")
    func sensitiveContentPolicyOnView() async {
        let runner = ProvenanceListRunner(version: "2.7.0", lists: [:],
            failures: ["view": "Error: Viewing the contents of this item is not allowed by policy"])
        do {
            _ = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).viewItem(itemId: "item", shareId: "share")
            Issue.record("Expected a policy restriction")
        } catch let error as CLIError {
            guard case .sensitiveContentRestricted = error else { Issue.record("Unexpected \(error)"); return }
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    @Test("newer unlisted releases keep shape-valid content as unverified, never verified", arguments: ["2.5.0", "2.7.1", "3.0.0"])
    func unlistedNewerInvocations(version: String) async throws {
        let incomplete = Self.completeNote.replacingOccurrences(of: #""note":"","#, with: "")
            .replacingOccurrences(of: #""vault_id":"vault""#, with: #""vault_id":"second-vault""#)
            .replacingOccurrences(of: #""share_id":"share""#, with: #""share_id":"second-share""#)
        let runner = ProvenanceListRunner(version: version, lists: [
            "share": Data(Self.completeNote.utf8), "second-share": Data(incomplete.utf8)
        ])
        let result = try await PassCLIService(cliPath: "/synthetic/pass-cli", runner: runner).fetchAllItems()
        #expect(result.contentProvenanceByVaultID["vault"] == .unverifiedCompleteJSON)
        #expect(result.contentProvenanceByVaultID["second-vault"] == .unavailable)
    }

    private func parse(
        _ json: String, provenance: CLISnapshotContentProvenance = .unavailable
    ) throws -> CLIItemListParseResult {
        try CLIItemListLossyParser.parse(
            Data(json.utf8), vaultId: "vault", vaultName: "Vault", shareId: "share", contentProvenance: provenance
        )
    }

    private static let completeNote = """
        {"items":[{"id":"item","share_id":"share","vault_id":"vault","state":"Active","flags":[],
         "create_time":"2026-10-01T12:00:00","modify_time":"2026-10-01T12:00:00",
         "content":{"title":"Synthetic","note":"","item_uuid":"uuid","content":{"Note":null},"extra_fields":[]}}]}
        """
}

private struct ProvenanceListRunner: CLIRunning {
    let version: String
    let lists: [String: Data]
    /// stderr text by share ID, or "view" for item view.
    var failures: [String: String] = [:]

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        if arguments == ["--version"] { return Data("Proton Pass CLI \(version)".utf8) }
        if arguments.starts(with: ["item", "view"]), let message = failures["view"] {
            throw CLIError.commandFailed(message)
        }
        if arguments == ["vault", "list", "--output", "json"] {
            return Data("""
                {"vaults":[
                {"name":"Vault","vault_id":"vault","share_id":"share"},
                {"name":"Second","vault_id":"second-vault","share_id":"second-share"}]}
                """.utf8)
        }
        let shareID = arguments.first(where: { $0.hasPrefix("--share-id=") }).map { String($0.dropFirst("--share-id=".count)) }
        if let shareID, let message = failures[shareID] { throw CLIError.commandFailed(message) }
        guard let shareID, let data = lists[shareID] else {
            throw CLIError.commandFailed("Unexpected synthetic invocation")
        }
        return data
    }
}

private actor SyncContentRunner: CLIRunning {
    private let versionGate: OfflineTestGate
    private var paths: [String] = []

    init(versionGate: OfflineTestGate) { self.versionGate = versionGate }

    func listPaths() -> [String] { paths }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        if arguments == ["--version"] {
            try await versionGate.wait()
            return Data("Proton Pass CLI 2.4.2 (ef5f645)".utf8)
        }
        paths.append(executablePath)
        return Data(#"{"items":[]}"#.utf8)
    }
}
