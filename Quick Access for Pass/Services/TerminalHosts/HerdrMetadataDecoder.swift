import Foundation

/// Allowlisted metadata only: unknown fields (including agent sessions and argv) are never decoded.
nonisolated enum HerdrMetadataDecoder {
    nonisolated struct Workspace: Decodable, Sendable {
        let workspaceID: String
        let label: String?
        enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id", label }
    }
    nonisolated struct Tab: Decodable, Sendable {
        let tabID: String
        let workspaceID: String
        let label: String?
        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id", workspaceID = "workspace_id", label
        }
    }
    nonisolated struct Pane: Decodable, Sendable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        let terminalTitleStripped: String?
        let foregroundCWD: String?
        let cwd: String?
        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id"
            case terminalTitleStripped = "terminal_title_stripped", foregroundCWD = "foreground_cwd", cwd
        }

        func hasSameAssociation(as other: Pane) -> Bool {
            paneID == other.paneID && workspaceID == other.workspaceID && tabID == other.tabID
        }
    }
    nonisolated struct Snapshot: Decodable, Sendable {
        let `protocol`: UInt32
        let workspaces: [Workspace]
        let tabs: [Tab]
        let panes: [Pane]

        func details(for pane: Pane, homeDirectory: String) -> HerdrPaneDetails {
            .init(workspaceLabel: sanitize(workspaces.first { $0.workspaceID == pane.workspaceID }?.label, homeDirectory: homeDirectory),
                  tabLabel: sanitize(tabs.first { $0.tabID == pane.tabID }?.label, homeDirectory: homeDirectory),
                  paneTitle: sanitize(pane.terminalTitleStripped, homeDirectory: homeDirectory),
                  workingDirectory: sanitize(pane.foregroundCWD ?? pane.cwd, homeDirectory: homeDirectory))
        }
    }
    nonisolated private struct SnapshotEnvelope: Decodable {
        nonisolated struct Result: Decodable {
            let type: String
            let snapshot: Snapshot
        }
        let result: Result
    }
    nonisolated private struct ProcessEnvelope: Decodable {
        nonisolated struct Result: Decodable {
            nonisolated struct Info: Decodable {
                let paneID: String
                let shellPID: UInt32?
                enum CodingKeys: String, CodingKey { case paneID = "pane_id", shellPID = "shell_pid" }
            }
            let type: String
            let processInfo: Info
            enum CodingKeys: String, CodingKey { case type, processInfo = "process_info" }
        }
        let result: Result
    }

    static func snapshot(_ data: Data) throws -> Snapshot {
        let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: data)
        let snapshot = envelope.result.snapshot
        // The installed, verified schema is protocol 22. Future protocols fail best-effort closed.
        let workspaceIDs = snapshot.workspaces.map(\.workspaceID)
        let tabIDs = snapshot.tabs.map(\.tabID)
        guard envelope.result.type == "session_snapshot", snapshot.protocol == 22,
              snapshot.panes.count <= 32, uniqueIDs(workspaceIDs), uniqueIDs(tabIDs),
              uniqueIDs(snapshot.panes.map(\.paneID)) else { throw CLIError.parseError("Unsupported Herdr metadata") }
        let workspaceIDSet = Set(workspaceIDs)
        let tabWorkspaces = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.tabID, $0.workspaceID) })
        guard snapshot.tabs.allSatisfy({ workspaceIDSet.contains($0.workspaceID) }),
              snapshot.panes.allSatisfy({ tabWorkspaces[$0.tabID] == $0.workspaceID }) else {
            throw CLIError.parseError("Incoherent Herdr metadata")
        }
        return snapshot
    }

    static func shellPID(_ data: Data, requestedPaneID: String) throws -> pid_t? {
        let envelope = try JSONDecoder().decode(ProcessEnvelope.self, from: data)
        guard envelope.result.type == "pane_process_info", envelope.result.processInfo.paneID == requestedPaneID else {
            throw CLIError.parseError("Mismatched Herdr pane")
        }
        guard let pid = envelope.result.processInfo.shellPID else { return nil }
        guard pid > 0, pid <= UInt32(Int32.max) else { throw CLIError.parseError("Invalid Herdr shell PID") }
        return pid_t(pid)
    }

    private static func uniqueIDs(_ ids: [String]) -> Bool {
        ids.allSatisfy { id in
            !id.isEmpty && id.count <= 256 && !id.hasPrefix("-")
                && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        } && Set(ids).count == ids.count
    }

    static func sanitize(_ value: String?, homeDirectory: String) -> String? {
        guard let value else { return nil }
        var filter = TerminalEscapeFilter()
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if let visible = filter.visibleScalar(scalar) { scalars.append(visible) }
        }
        var text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if !homeDirectory.isEmpty && homeDirectory != "/" {
            if text == homeDirectory { text = "~" }
            else if text.hasPrefix(homeDirectory + "/") { text = "~" + text.dropFirst(homeDirectory.count) }
        }
        text = String(text.prefix(256))
        return text.isEmpty ? nil : text
    }

    /// Strip complete escape sequences, including their printable payload, and all line/format controls.
    nonisolated private struct TerminalEscapeFilter {
        private enum State { case text, escape, csi, string, stringEscape }
        private var state = State.text

        mutating func visibleScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
            switch state {
            case .text: return textScalar(scalar)
            case .escape: consumeEscape(scalar)
            case .csi:
                if (0x40...0x7e).contains(scalar.value) { state = .text }
            case .string:
                if scalar.value == 0x07 || scalar.value == 0x9c { state = .text }
                else if scalar.value == 0x1b { state = .stringEscape }
            case .stringEscape:
                state = scalar.value == 0x5c ? .text : .string
            }
            return nil
        }

        private mutating func textScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
            switch scalar.value {
            case 0x1b: state = .escape
            case 0x9b: state = .csi
            case 0x90, 0x9d, 0x9e, 0x9f: state = .string
            default:
                if !CharacterSet.controlCharacters.contains(scalar), !CharacterSet.newlines.contains(scalar),
                   scalar.properties.generalCategory != .format { return scalar }
            }
            return nil
        }

        private mutating func consumeEscape(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x5b: state = .csi
            case 0x5d, 0x50, 0x5e, 0x5f: state = .string
            case 0x20...0x2f: break
            default: state = .text
            }
        }
    }

}
