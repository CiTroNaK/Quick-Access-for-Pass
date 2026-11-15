import Foundation

/// Decodes one Herdr Core `terminal.get` JSON-RPC response. Only the listed fields are read; the rest is ignored.
nonisolated enum HerdrCoreTerminalDecoder {
    nonisolated struct Terminal: Equatable, Sendable {
        let address: String
        let name: String?
        let title: String?
        let pid: pid_t
        let state: String
        /// The `where` label Herdr.app sets on its terminals (`workspace / tab`).
        var workspaceAndTab: String?
    }

    nonisolated private struct Response: Decodable {
        let id: Int
        let result: Terminal
    }

    static func terminal(fromResponse data: Data) throws -> Terminal {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CLIError.parseError("Invalid Herdr Core terminal metadata")
        }
        guard response.id == 1 else { throw CLIError.parseError("Unexpected Herdr Core response") }
        return response.result
    }

    static func details(terminal: Terminal, workingDirectory: String?,
                        homeDirectory: String) -> HerdrPaneDetails? {
        let label = HerdrMetadataDecoder.sanitize(terminal.name, homeDirectory: homeDirectory)
            ?? HerdrMetadataDecoder.sanitize(terminal.title, homeDirectory: homeDirectory)
        // Herdr.app's `where` label is already `workspace / tab`, so it fills the workspace part on its own.
        let details = HerdrPaneDetails(
            workspaceLabel: HerdrMetadataDecoder.sanitize(terminal.workspaceAndTab, homeDirectory: homeDirectory),
            tabLabel: nil,
            paneTitle: label,
            workingDirectory: HerdrMetadataDecoder.sanitize(workingDirectory, homeDirectory: homeDirectory))
        guard details.workspaceLabel != nil || details.paneTitle != nil || details.workingDirectory != nil else { return nil }
        return details
    }
}

extension HerdrCoreTerminalDecoder.Terminal: Decodable {
    private enum CodingKeys: String, CodingKey { case address, name, title, pid, state, labels }
    private enum LabelKeys: String, CodingKey { case `where` }

    /// Labels are free-form; an unusable `where` label is dropped without rejecting the terminal.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(String.self, forKey: .address)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        pid = try container.decode(pid_t.self, forKey: .pid)
        state = try container.decode(String.self, forKey: .state)
        let labels = try? container.nestedContainer(keyedBy: LabelKeys.self, forKey: .labels)
        workspaceAndTab = (try? labels?.decodeIfPresent(String.self, forKey: .where)) ?? nil
    }
}
