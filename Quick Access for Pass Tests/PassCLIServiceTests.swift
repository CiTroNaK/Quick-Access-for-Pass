import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("PassCLIService Tests")
struct PassCLIServiceTests {
    @Test("findCLIPath finds pass-cli in common locations")
    func findCLI() {
        let service = PassCLIService(cliPath: "/nonexistent/pass-cli")
        #expect(service.cliPath == "/nonexistent/pass-cli")
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

    @Test("updateCLIPath replaces the current path without reconstructing the service")
    func updateCLIPathRoundTrip() {
        let service = PassCLIService(cliPath: "/initial/pass-cli")
        #expect(service.cliPath == "/initial/pass-cli")

        service.updateCLIPath("/replacement/pass-cli")
        #expect(service.cliPath == "/replacement/pass-cli")
    }
}
