import Darwin
import Foundation

nonisolated protocol HerdrPaneDetailsProviding: Sendable {
    func details(for match: TerminalHostMatch) async -> HerdrPaneDetails?
}

nonisolated struct HerdrSocketIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: uid_t

    static func read(_ path: String) -> Self? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              info.st_uid == getuid(), access(path, R_OK | W_OK) == 0 else { return nil }
        return .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), owner: info.st_uid)
    }
}

nonisolated struct LiveHerdrPaneDetailsProvider: HerdrPaneDetailsProviding {
    typealias CommandRunner = @Sendable (String, [String], [String: String], CLIExecutionDeadline, Int) async throws -> Data
    private let runCommand: CommandRunner
    private let readProcess: @Sendable (pid_t) -> RequesterProcessSnapshot.ProcessNode?
    private let readSocket: @Sendable (String) -> HerdrSocketIdentity?
    private let inheritedEnvironmentKeys: @Sendable () -> [String]
    private let homeDirectory: String
    private let now: @Sendable () -> UInt64

    private struct PaneAssociation: Hashable {
        let paneID: String
        let workspaceID: String
        let tabID: String

        init(_ pane: HerdrMetadataDecoder.Pane) {
            paneID = pane.paneID
            workspaceID = pane.workspaceID
            tabID = pane.tabID
        }
    }

    init(
        runCommand: @escaping CommandRunner = { path, args, env, deadline, limit in
            try await CLIRunner.run(executablePath: path, arguments: args, environmentOverrides: env,
                                    deadline: deadline, maximumOutputBytes: limit)
        },
        readProcess: @escaping @Sendable (pid_t) -> RequesterProcessSnapshot.ProcessNode? = { RequesterProcessCapture.readNode($0) },
        readSocket: @escaping @Sendable (String) -> HerdrSocketIdentity? = { HerdrSocketIdentity.read($0) },
        inheritedEnvironmentKeys: @escaping @Sendable () -> [String] = { Array(ProcessInfo.processInfo.environment.keys) },
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.runCommand = runCommand
        self.readProcess = readProcess
        self.readSocket = readSocket
        self.inheritedEnvironmentKeys = inheritedEnvironmentKeys
        self.homeDirectory = homeDirectory
        self.now = now
    }

    /// Request-scoped, fixed read-only commands. A hint routes the query but never proves pane ownership.
    @concurrent func details(for match: TerminalHostMatch) async -> HerdrPaneDetails? {
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: now() + 750_000_000)
        guard let hint = match.routingHint, validSocketPath(hint.socketPath),
              match.requesterSideNodes.contains(where: {
                  $0.pid == hint.originatingPID && $0.startTimeMicroseconds == hint.originatingStartTimeMicroseconds
              }),
              let socket = readSocket(hint.socketPath), socket.owner == getuid(), revalidate(match) else { return nil }
        let environment = routingEnvironment(socketPath: hint.socketPath)
        do {
            let snapshot = try HerdrMetadataDecoder.snapshot(await command(["api", "snapshot"], match, environment, deadline))
            var candidates = snapshot.panes
            let eligiblePIDs = Set(match.requesterSideNodes.map(\.pid))
            var matches: [HerdrMetadataDecoder.Pane] = []
            if let index = candidates.firstIndex(where: { $0.paneID == hint.paneID }) {
                let hintedPane = candidates.remove(at: index)
                if let matched = try await matchingPane(hintedPane, eligiblePIDs: eligiblePIDs, match: match,
                                                        environment: environment, deadline: deadline) { matches.append(matched) }
            }
            matches += try await scan(candidates, eligiblePIDs: eligiblePIDs, match: match, environment: environment, deadline: deadline)
            guard matches.count == 1, let pane = matches.first else { return nil }
            let current = try HerdrMetadataDecoder.snapshot(await command(["api", "snapshot"], match, environment, deadline))
            // A changed candidate set invalidates the completed unique-ownership scan, regardless of order or labels.
            guard Set(snapshot.panes.map(PaneAssociation.init)) == Set(current.panes.map(PaneAssociation.init)),
                  let currentPane = current.panes.first(where: { $0.paneID == pane.paneID }),
                  pane.hasSameAssociation(as: currentPane),
                  readSocket(hint.socketPath) == socket, revalidate(match) else { return nil }
            try checkBudget(deadline)
            return current.details(for: currentPane, homeDirectory: homeDirectory)
        } catch {
            // No raw output/error metadata is retained or logged, including normal cancellation fallback.
            return nil
        }
    }

    private func scan(
        _ panes: [HerdrMetadataDecoder.Pane], eligiblePIDs: Set<pid_t>, match: TerminalHostMatch,
        environment: [String: String], deadline: CLIExecutionDeadline
    ) async throws -> [HerdrMetadataDecoder.Pane] {
        try await withThrowingTaskGroup(of: HerdrMetadataDecoder.Pane?.self) { group in
            defer { group.cancelAll() }
            var next = 0
            func addCandidate(_ pane: HerdrMetadataDecoder.Pane) {
                group.addTask {
                    try await matchingPane(pane, eligiblePIDs: eligiblePIDs, match: match, environment: environment, deadline: deadline)
                }
            }
            for pane in panes.prefix(4) { addCandidate(pane); next += 1 }
            var matches: [HerdrMetadataDecoder.Pane] = []
            while let result = try await group.next() {
                try checkBudget(deadline)
                if let result { matches.append(result) }
                // Never stop at the hinted/first match: every candidate must finish to establish uniqueness.
                if next < panes.count { addCandidate(panes[next]); next += 1 }
            }
            return matches
        }
    }

    private func matchingPane(_ pane: HerdrMetadataDecoder.Pane, eligiblePIDs: Set<pid_t>, match: TerminalHostMatch,
                              environment: [String: String], deadline: CLIExecutionDeadline) async throws -> HerdrMetadataDecoder.Pane? {
        let data = try await command(["pane", "process-info", "--pane", pane.paneID], match, environment, deadline)
        // Optional/null permits unavailable inspection, not proven absence, in the verified schema.
        // Every candidate needs a usable PID before a positive match can be called unique.
        guard let pid = try HerdrMetadataDecoder.shellPID(data, requestedPaneID: pane.paneID) else {
            throw CLIError.parseError("Incomplete Herdr ownership metadata")
        }
        return eligiblePIDs.contains(pid) ? pane : nil
    }

    private func command(_ arguments: [String], _ match: TerminalHostMatch, _ environment: [String: String],
                         _ deadline: CLIExecutionDeadline) async throws -> Data {
        try checkBudget(deadline)
        let data = try await runCommand(match.executablePath, arguments, environment, deadline, 512 * 1024)
        try checkBudget(deadline)
        guard data.count <= 512 * 1024 else { throw CLIError.outputLimitExceeded }
        return data
    }

    private func checkBudget(_ deadline: CLIExecutionDeadline) throws {
        try Task.checkCancellation()
        _ = try deadline.remainingSeconds(at: now())
    }

    private func revalidate(_ match: TerminalHostMatch) -> Bool {
        let nodes = match.requesterSideNodes + [match.host]
        guard !match.requesterSideNodes.isEmpty, nodes.count <= 11, Set(nodes.map(\.pid)).count == nodes.count,
              nodes.allSatisfy({ $0.pid > 1 && $0.startTimeMicroseconds > 0 && readProcess($0.pid) == $0 }) else { return false }
        return zip(nodes, nodes.dropFirst()).allSatisfy { $0.parentPID == $1.pid }
    }

    private func validSocketPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func routingEnvironment(socketPath: String) -> [String: String] {
        // Clear even unknown future inherited Herdr selectors. Only keys are inspected/retained.
        let knownSelectors = ["HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID", "HERDR_SESSION", "HERDR_SESSION_NAME",
                              "HERDR_MACHINE", "HERDR_MACHINE_ID", "HERDR_REMOTE", "HERDR_CONFIG_PATH", "HERDR_BIN_PATH", "HERDR_ENV"]
        var overrides = Dictionary(uniqueKeysWithValues: knownSelectors.map { ($0, "") })
        for key in inheritedEnvironmentKeys() where key.hasPrefix("HERDR_") { overrides[key] = "" }
        overrides["HERDR_SOCKET_PATH"] = socketPath
        return overrides
    }
}
