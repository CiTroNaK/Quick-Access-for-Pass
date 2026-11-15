import Darwin
import Foundation
import os

nonisolated struct HerdrCoreLookup: Equatable, Sendable {
    let herdrAppURL: URL?
    /// Mapped into Herdr's details so both products share the same header rows.
    let details: HerdrPaneDetails?
}

nonisolated protocol HerdrCoreTerminalDetailsProviding: Sendable {
    /// nil when the holder is not verified as Herdr Core (keep today's presentation). A non-nil result is
    /// recognized; its details are nil when not requested or when ownership cannot be proven in time.
    func lookup(_ match: HerdrCoreTerminalMatch, includeDetails: Bool) async -> HerdrCoreLookup?
}

nonisolated struct LiveHerdrCoreTerminalDetailsProvider: HerdrCoreTerminalDetailsProviding {
    static let budgetNanoseconds: UInt64 = 750_000_000

    private let query: any HerdrCoreSocketQuerying
    private let verifier: any HerdrCodeSignatureVerifying
    private let readProcess: @Sendable (pid_t) -> RequesterProcessSnapshot.ProcessNode?
    private let readSocket: @Sendable (String) -> HerdrSocketIdentity?
    private let readWorkingDirectory: @Sendable (pid_t) -> String?
    private let homeDirectory: String
    private let now: @Sendable () -> UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(
        query: any HerdrCoreSocketQuerying,
        verifier: any HerdrCodeSignatureVerifying,
        readProcess: @escaping @Sendable (pid_t) -> RequesterProcessSnapshot.ProcessNode? = { RequesterProcessCapture.readNode($0) },
        readSocket: @escaping @Sendable (String) -> HerdrSocketIdentity? = { HerdrSocketIdentity.read($0) },
        readWorkingDirectory: @escaping @Sendable (pid_t) -> String? = { RequesterProcessCapture.readWorkingDirectory($0) },
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.query = query
        self.verifier = verifier
        self.readProcess = readProcess
        self.readSocket = readSocket
        self.readWorkingDirectory = readWorkingDirectory
        self.homeDirectory = homeDirectory
        self.now = now
        self.sleep = sleep
    }

    /// One request-scoped attempt under one absolute deadline. The socket hint routes the query; ownership is
    /// proven only by the verified Core peer reporting the requester's own terminal root process.
    @concurrent func lookup(_ match: HerdrCoreTerminalMatch, includeDetails: Bool) async -> HerdrCoreLookup? {
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: now() + Self.budgetNanoseconds)
        guard (try? checkBudget(deadline)) != nil else { return nil }
        let verifier = verifier
        let holderPID = match.holder.pid
        // Signature checks can block; both run off the cooperative pool and are awaited only within the deadline.
        let holderCheck = BoundedBlockingWork { verifier.isVerifiedCore(pid: holderPID) }
        // Started alongside the holder check so it gets the whole budget; it is static, cached and display-only.
        let appCheck = BoundedBlockingWork { verifier.verifiedHerdrAppURL() }
        guard await holderCheck.value(within: remainingNanoseconds(deadline), sleep: sleep) == true,
              // A recycled PID could have satisfied the signature check; the start-time recheck rules that out.
              revalidate(match), (try? checkBudget(deadline)) != nil else { return nil }
        let details = includeDetails ? try? await details(for: match, deadline: deadline) : nil
        // A finished check is used even after the deadline, so a slow Core reply never costs the icon.
        let appURL = await appCheck.value(within: remainingNanoseconds(deadline), sleep: sleep) ?? nil
        return .init(herdrAppURL: appURL, details: details)
    }

    private func details(for match: HerdrCoreTerminalMatch, deadline: CLIExecutionDeadline) async throws -> HerdrPaneDetails? {
        let path = match.hint.socketPath
        guard TerminalHostLookupChecks.isValidSocketPath(path), let socket = readSocket(path), socket.owner == getuid() else {
            return nil
        }
        let data = try await query.terminalGet(socketPath: path, terminalID: match.hint.terminalID, deadline: deadline)
        try checkBudget(deadline)
        let terminal = try HerdrCoreTerminalDecoder.terminal(fromResponse: data)
        guard terminal.address == match.hint.terminalID, terminal.state == "live",
              terminal.pid == match.terminalRoot.pid else { return nil }
        let folderNode = match.programNode ?? match.requesterSideNodes[0]
        let folder = readWorkingDirectory(folderNode.pid)
        // Read the folder before the final recheck so a recycled PID cannot contribute it.
        guard readSocket(path) == socket, revalidate(match) else { return nil }
        try checkBudget(deadline)
        return HerdrCoreTerminalDecoder.details(terminal: terminal, workingDirectory: folder, homeDirectory: homeDirectory)
    }

    private func remainingNanoseconds(_ deadline: CLIExecutionDeadline) -> UInt64 {
        guard let seconds = try? deadline.remainingSeconds(at: now()) else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }

    private func checkBudget(_ deadline: CLIExecutionDeadline) throws {
        try TerminalHostLookupChecks.checkBudget(deadline, now: now())
    }

    /// The resolver guarantees the terminal root is the last requester-side node directly under the holder.
    private func revalidate(_ match: HerdrCoreTerminalMatch) -> Bool {
        TerminalHostLookupChecks.isChainIntact(match.requesterSideNodes, host: match.holder, readProcess: readProcess)
    }
}

/// Used where no shared live provider is composed (tests and previews); never recognizes Core.
nonisolated struct UnavailableHerdrCoreDetailsProvider: HerdrCoreTerminalDetailsProviding {
    func lookup(_ match: HerdrCoreTerminalMatch, includeDetails: Bool) async -> HerdrCoreLookup? { nil }
}
