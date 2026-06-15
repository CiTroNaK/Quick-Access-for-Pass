import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("PassCLIService Tests")
struct PassCLIServiceTests {
    @Test("custom init path is stored as custom selection")
    func customInitPathIsStoredAsCustomSelection() {
        let service = PassCLIService(cliPath: "/nonexistent/pass-cli")

        #expect(service.cliPath == "/nonexistent/pass-cli")
        #expect(service.cliSelection == .custom(path: "/nonexistent/pass-cli"))
    }

    @Test("parseVaultListOutput parses valid JSON")
    func parseVaultList() throws {
        let json = """
        {"vaults":[{"name":"Personal","vault_id":"v1","share_id":"s1"}]}
        """
        let vaults = try PassCLIService.parseVaultList(from: json.data(using: .utf8)!)
        #expect(vaults.count == 1)
        #expect(vaults[0].name == "Personal")
    }

    @Test("parseItemListOutput parses valid JSON")
    func parseItemList() throws {
        let json = """
        {"items":[{
            "id":"i1","share_id":"s1","vault_id":"v1",
            "content":{"title":"Test","note":"","item_uuid":"u1",
                "content":{"Note":null},"extra_fields":[]},
            "state":"Active","flags":[],
            "create_time":"2025-01-01T00:00:00","modify_time":"2025-01-01T00:00:00"
        }]}
        """
        let items = try PassCLIService.parseItemList(from: json.data(using: .utf8)!)
        #expect(items.count == 1)
        #expect(items[0].content.title == "Test")
    }

    @Test("parseItemListOutput reports missing keys with coding path")
    func parseItemListReportsMissingKeyPath() throws {
        let json = """
        {"items":[{
            "id":"i1","share_id":"s1","vault_id":"v1",
            "content":{"title":"Test","note":"","item_uuid":"u1","extra_fields":[]},
            "state":"Active","flags":[],
            "create_time":"2025-01-01T00:00:00","modify_time":"2025-01-01T00:00:00"
        }]}
        """

        do {
            _ = try PassCLIService.parseItemList(from: Data(json.utf8))
            Issue.record("Expected missing content key to throw")
        } catch let error as CLIError {
            let description = try #require(error.errorDescription)
            #expect(description.contains("item list"))
            #expect(description.contains("missing 'content'"))
            #expect(description.contains("items"))
        }
    }

    @Test("parseTotpOutput parses valid JSON")
    func parseTotp() throws {
        let json = """
        {"totp_uri":"123456","totp":"123456"}
        """
        let code = try PassCLIService.parseTotp(from: json.data(using: .utf8)!)
        #expect(code == "123456")
    }

    @Test("CLIError provides useful descriptions")
    func errorDescriptions() {
        let notFound = CLIError.notInstalled
        #expect(notFound.errorDescription?.contains("pass-cli") == true)

        let notLoggedIn = CLIError.notLoggedIn
        #expect(notLoggedIn.errorDescription?.contains("login") == true)
    }

    @Test("updating with blank custom path re-runs auto resolution")
    func updateCustomPathToBlankRerunsAutoResolution() {
        let resolver = PassCLIResolver(
            fileSystem: StubExecutableFileSystem(executablePaths: ["/opt/homebrew/bin/pass-cli"]),
            which: StubWhichResolver(path: nil),
            bundleURL: URL(fileURLWithPath: "/Applications/Quick Access for Pass.app"),
            architecture: .arm64
        )
        let service = PassCLIService(cliPath: "/custom/pass-cli", resolver: resolver)

        let didChange = service.updateCLISelection(customPath: "")

        #expect(didChange)
        #expect(service.cliSelection == .system(path: "/opt/homebrew/bin/pass-cli"))
        #expect(service.cliPath == "/opt/homebrew/bin/pass-cli")
    }

    @Test("updating with same resolved selection returns false")
    func updateSameResolvedSelectionReturnsFalse() {
        let resolver = PassCLIResolver(
            fileSystem: StubExecutableFileSystem(executablePaths: ["/opt/homebrew/bin/pass-cli"]),
            which: StubWhichResolver(path: nil),
            bundleURL: URL(fileURLWithPath: "/Applications/Quick Access for Pass.app"),
            architecture: .arm64
        )
        let service = PassCLIService(cliPath: nil, resolver: resolver)

        let didChange = service.updateCLISelection(customPath: nil)

        #expect(didChange == false)
        #expect(service.cliSelection == .system(path: "/opt/homebrew/bin/pass-cli"))
    }

    @Test("listItems includes show-secrets for CLI 2.0.3 and newer")
    func listItemsIncludesShowSecretsForCLI203AndNewer() async throws {
        for versionOutput in [
            "Proton Pass CLI 2.0.3 (47f0458)\n",
            "Proton Pass CLI 2.1.0 (47f0458)\n"
        ] {
            let runner = RecordingPassCLIRunner(versionOutput: versionOutput)
            let service = PassCLIService(cliPath: "/fake/pass-cli", runner: runner)

            _ = try await service.listItems(shareId: "share-1")

            let versionArguments = try #require(await runner.arguments(forCommand: "--version"))
            #expect(versionArguments == ["--version"])
            let itemListArguments = try #require(await runner.arguments(forCommand: "item", "list"))
            #expect(itemListArguments == ["item", "list", "--share-id=share-1", "--output", "json", "--show-secrets"])
        }
    }

    @Test("listItems omits show-secrets for CLI versions before 2.0.3")
    func listItemsOmitsShowSecretsForOlderCLI() async throws {
        let runner = RecordingPassCLIRunner(versionOutput: "Proton Pass CLI 2.0.2 (47f0458)\n")
        let service = PassCLIService(cliPath: "/fake/pass-cli", runner: runner)

        _ = try await service.listItems(shareId: "share-1")

        let itemListArguments = try #require(await runner.arguments(forCommand: "item", "list"))
        #expect(itemListArguments == ["item", "list", "--share-id=share-1", "--output", "json"])
    }

    @Test("listItems omits show-secrets when CLI version cannot be parsed")
    func listItemsOmitsShowSecretsForUnparsableCLIVersion() async throws {
        let runner = RecordingPassCLIRunner(versionOutput: "Proton Pass CLI development build\n")
        let service = PassCLIService(cliPath: "/fake/pass-cli", runner: runner)

        _ = try await service.listItems(shareId: "share-1")

        let itemListArguments = try #require(await runner.arguments(forCommand: "item", "list"))
        #expect(itemListArguments == ["item", "list", "--share-id=share-1", "--output", "json"])
    }

    @Test("listItems caches the show-secrets capability across concurrent sync work")
    func listItemsCachesShowSecretsCapabilityAcrossConcurrentSyncWork() async throws {
        let runner = RecordingPassCLIRunner(versionOutput: "Proton Pass CLI 2.1.0 (47f0458)\n")
        let service = PassCLIService(cliPath: "/fake/pass-cli", runner: runner)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for shareId in ["share-1", "share-2", "share-3"] {
                group.addTask {
                    _ = try await service.listItems(shareId: shareId)
                }
            }
            try await group.waitForAll()
        }

        #expect(await runner.invocationCount(forCommand: "--version") == 1)
    }

    @Test("updateCLIPath invalidates cached show-secrets capability")
    func updateCLIPathInvalidatesCachedShowSecretsCapability() async throws {
        let runner = RecordingPassCLIRunner(versionOutputByPath: [
            "/new/pass-cli": "Proton Pass CLI 2.1.0 (47f0458)\n",
            "/old/pass-cli": "Proton Pass CLI 2.0.2 (47f0458)\n"
        ])
        let service = PassCLIService(cliPath: "/new/pass-cli", runner: runner)

        _ = try await service.listItems(shareId: "share-1")
        service.updateCLIPath("/old/pass-cli")
        _ = try await service.listItems(shareId: "share-2")

        #expect(await runner.invocationCount(forCommand: "--version") == 2)
        let itemListInvocations = await runner.argumentsList(forCommand: "item", "list")
        #expect(itemListInvocations == [
            ["item", "list", "--share-id=share-1", "--output", "json", "--show-secrets"],
            ["item", "list", "--share-id=share-2", "--output", "json"]
        ])
    }

    @Test("viewItem decodes full secret content on demand")
    func viewItemDecodesFullSecretContentOnDemand() async throws {
        let runner = RecordingPassCLIRunner()
        let service = PassCLIService(cliPath: "/fake/pass-cli", runner: runner)

        let item = try await service.viewItem(itemId: "login1", shareId: "s1")

        let viewArguments = try #require(await runner.arguments(forCommand: "item", "view"))
        #expect(viewArguments == ["item", "view", "--output", "json", "pass://s1/login1"])
        guard case .login(let login) = item.content.content else {
            Issue.record("Expected viewItem fixture to decode as a login")
            return
        }
        #expect(login.password == "secret-password")
        #expect(login.urls == ["https://example.com"])
    }

    @Test("PassItem metadata encoding excludes decoded secret values")
    func passItemMetadataEncodingExcludesDecodedSecretValues() throws {
        let json = """
        {"items":[
            {
                "id":"login1","share_id":"s1","vault_id":"v1",
                "content":{"title":"Login","note":"","item_uuid":"u-login",
                    "content":{"Login":{
                        "email":"user@example.com",
                        "username":"user",
                        "password":"secret-login-password",
                        "urls":["https://example.com"],
                        "totp_uri":"otpauth://totp/secret-login-totp"
                    }},"extra_fields":[{"name":"Login hidden","content":{"Hidden":"secret-login-hidden"}}]},
                "state":"Active","flags":[],
                "create_time":"2025-01-01T00:00:00","modify_time":"2025-01-01T00:00:00"
            },
            {
                "id":"card1","share_id":"s1","vault_id":"v1",
                "content":{"title":"Card","note":"","item_uuid":"u-card",
                    "content":{"CreditCard":{
                        "cardholder_name":"Taylor",
                        "card_type":"Visa",
                        "number":"secret-card-number",
                        "verification_number":"secret-card-cvv",
                        "expiration_date":"12/2030",
                        "pin":"secret-card-pin"
                    }},"extra_fields":[]},
                "state":"Active","flags":[],
                "create_time":"2025-01-01T00:00:00","modify_time":"2025-01-01T00:00:00"
            },
            {
                "id":"ssh1","share_id":"s1","vault_id":"v1",
                "content":{"title":"SSH","note":"","item_uuid":"u-ssh",
                    "content":{"SshKey":{
                        "private_key":"secret-private-key",
                        "public_key":"ssh-ed25519 public"
                    }},"extra_fields":[]},
                "state":"Active","flags":[],
                "create_time":"2025-01-01T00:00:00","modify_time":"2025-01-01T00:00:00"
            }
        ]}
        """
        let secretValues = [
            "secret-login-password",
            "otpauth://totp/secret-login-totp",
            "secret-login-hidden",
            "secret-card-number",
            "secret-card-cvv",
            "secret-card-pin",
            "secret-private-key"
        ]

        let cliItems = try PassCLIService.parseItemList(from: Data(json.utf8))
        let passItems = cliItems.map { PassItem(from: $0, vaultId: $0.vaultId) }
        let encodedMetadata = try passItems
            .map { try #require(String(data: try JSONEncoder().encode($0), encoding: .utf8)) }
            .joined(separator: "\n")

        for secretValue in secretValues {
            #expect(encodedMetadata.contains(secretValue) == false)
        }
    }
}

private struct StubExecutableFileSystem: ExecutableFileChecking {
    let executablePaths: Set<String>

    nonisolated func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private struct StubWhichResolver: WhichResolving {
    let path: String?

    nonisolated func find(_ executableName: String) -> String? {
        path
    }
}

private actor RecordingPassCLIRunner: CLIRunning {
    private let versionOutput: String
    private let versionOutputByPath: [String: String]
    private var invocations: [[String]] = []

    init(
        versionOutput: String = "Proton Pass CLI 2.0.3 (47f0458)\n",
        versionOutputByPath: [String: String] = [:]
    ) {
        self.versionOutput = versionOutput
        self.versionOutputByPath = versionOutputByPath
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Data {
        invocations.append(arguments)

        if arguments == ["--version"] {
            return Data((versionOutputByPath[executablePath] ?? versionOutput).utf8)
        }

        if arguments.starts(with: ["item", "list"]) {
            return Data(Self.itemListJSON.utf8)
        }

        if arguments.starts(with: ["item", "view"]) {
            return Data(Self.itemViewJSON.utf8)
        }

        return Data("{}".utf8)
    }

    func arguments(forCommand command: String...) -> [String]? {
        invocations.first { invocation in
            invocation.starts(with: command)
        }
    }

    func invocationCount(forCommand command: String...) -> Int {
        invocations.count { invocation in
            invocation.starts(with: command)
        }
    }

    func argumentsList(forCommand command: String...) -> [[String]] {
        invocations.filter { invocation in
            invocation.starts(with: command)
        }
    }

    private static let itemListJSON = """
    {"items":[{
        "id":"i1","share_id":"s1","vault_id":"v1",
        "content":{"title":"Test","note":"","item_uuid":"u1",
            "content":{"Note":null},"extra_fields":[]},
        "state":"Active","flags":[],
        "create_time":"2025-01-01T00:00:00","modify_time":"2025-01-01T00:00:00"
    }]}
    """

    private static let itemViewJSON = """
    {"item":{
        "id":"login1","share_id":"s1","vault_id":"v1",
        "content":{"title":"Login","note":"","item_uuid":"u-login",
            "content":{"Login":{
                "email":"user@example.com",
                "username":"user",
                "password":"secret-password",
                "urls":["https://example.com"],
                "totp_uri":"otpauth://totp/example"
            }},"extra_fields":[]},
        "state":"Active","flags":[],
        "create_time":"2025-01-01T00:00:00","modify_time":"2025-01-01T00:00:00"
    }}
    """
}
