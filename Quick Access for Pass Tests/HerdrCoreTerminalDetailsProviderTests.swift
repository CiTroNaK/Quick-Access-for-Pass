import Darwin
import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

nonisolated private enum CoreFixture {
    static let home = "/Users/u"
    static let socket = "/Users/u/.local/state/herdr-core/default/default.sock"
    static let identity = HerdrSocketIdentity(device: 1, inode: 2, owner: getuid())
    static let app = URL(fileURLWithPath: "/Applications/Herdr.app")

    static func node(_ pid: Int32, _ path: String, parent: Int32) -> RequesterProcessSnapshot.ProcessNode {
        .init(pid: pid, parentPID: parent, startTimeMicroseconds: UInt64(pid), executablePath: path, canonicalExecutablePath: path)
    }
    static let nodes = [node(10, "/usr/bin/ssh", parent: 11), node(11, "/opt/claude", parent: 12),
                        node(12, "/bin/zsh", parent: 13), node(13, "/Herdr Core.app/Contents/MacOS/herdr-core", parent: 14)]
    static func match(socket: String = socket) -> HerdrCoreTerminalMatch {
        .init(holder: nodes[3], terminalRoot: nodes[2], requesterSideNodes: Array(nodes.prefix(3)),
              hint: .init(terminalID: "t5", socketPath: socket, originatingPID: 11, originatingStartTimeMicroseconds: 11),
              programNode: nodes[1])
    }
    static func response(address: String = "t5", pid: Int32 = 12, state: String = "live") -> Data {
        Data(#"{"jsonrpc":"2.0","id":1,"result":{"address":"\#(address)","name":null,"title":"Herdr core documentation","pid":\#(pid),"state":"\#(state)","cwd":"/x"}}"#.utf8)
    }
}

nonisolated private final class FakeCoreVerifier: HerdrCodeSignatureVerifying, Sendable {
    let holderVerified: Bool
    let peerVerified: Bool
    let appURL: URL?
    let blocksAppCheck: Bool
    let blocksPeerCheck: Bool
    private let appChecks = OSAllocatedUnfairLock(initialState: 0)

    init(holderVerified: Bool = true, peerVerified: Bool = true, appURL: URL? = CoreFixture.app, blocksAppCheck: Bool = false,
         blocksPeerCheck: Bool = false) {
        self.holderVerified = holderVerified
        self.peerVerified = peerVerified
        self.appURL = appURL
        self.blocksAppCheck = blocksAppCheck
        self.blocksPeerCheck = blocksPeerCheck
    }
    func isVerifiedCore(pid: pid_t) -> Bool { holderVerified && pid == 13 }
    func isVerifiedCore(auditToken: audit_token_t) -> Bool {
        if blocksPeerCheck {
            semaphore.withLock { $0 = true }
            gate.wait()
        }
        return peerVerified
    }
    func verifiedHerdrAppURL() -> URL? {
        appChecks.withLock { $0 += 1 }
        if blocksAppCheck {
            semaphore.withLock { $0 = true }
            gate.wait()
        }
        return appURL
    }
    private let gate = DispatchSemaphore(value: 0)
    private let semaphore = OSAllocatedUnfairLock(initialState: false)
    var isBlocked: Bool { semaphore.withLock { $0 } }
    func unblock() { gate.signal() }
}

private actor FakeCoreQuery: HerdrCoreSocketQuerying {
    enum Behavior: Sendable { case reply(Data), fail(any Error), late(Data), gated }
    let behavior: Behavior
    let clock: OSAllocatedUnfairLock<UInt64>
    var calls: [(socket: String, terminal: String)] = []
    var cancellationObserved = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false
    var onQuery: (@Sendable () -> Void)?

    init(_ behavior: Behavior, clock: OSAllocatedUnfairLock<UInt64>) {
        self.behavior = behavior
        self.clock = clock
    }
    func setOnQuery(_ action: @escaping @Sendable () -> Void) { onQuery = action }
    func started() async {
        if didStart { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    nonisolated func terminalGet(socketPath: String, terminalID: String, deadline: CLIExecutionDeadline) async throws -> Data {
        try await record(socketPath, terminalID)
    }
    private func record(_ socket: String, _ terminal: String) async throws -> Data {
        calls.append((socket, terminal))
        didStart = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters = []
        onQuery?()
        switch behavior {
        case .reply(let data): return data
        case .fail(let error): throw error
        case .late(let data):
            clock.withLock { $0 += 750_000_001 }
            return data
        case .gated:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancellationObserved = true
                throw error
            }
            return CoreFixture.response()
        }
    }
}

nonisolated private final class CoreWorld: Sendable {
    let clock = OSAllocatedUnfairLock<UInt64>(initialState: 10_000_000_000)
    let processes = OSAllocatedUnfairLock(initialState: Dictionary(uniqueKeysWithValues: CoreFixture.nodes.map { ($0.pid, $0) }))
    let socket = OSAllocatedUnfairLock<HerdrSocketIdentity?>(initialState: CoreFixture.identity)

    func provider(_ query: FakeCoreQuery, verifier: FakeCoreVerifier = .init(),
                  sleep: @escaping @Sendable (UInt64) async throws -> Void = { _ in try await Task.sleep(for: .seconds(30)) })
        -> LiveHerdrCoreTerminalDetailsProvider {
        .init(query: query, verifier: verifier,
              readProcess: { pid in self.processes.withLock { $0[pid] } },
              readSocket: { _ in self.socket.withLock { $0 } },
              readWorkingDirectory: { $0 == 11 ? "/Users/u/Code/p" : nil },
              homeDirectory: CoreFixture.home,
              now: { self.clock.withLock { $0 } }, sleep: sleep)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreTerminalDetailsProviderTests {
    private static let expected = HerdrPaneDetails(workspaceLabel: nil, tabLabel: nil, paneTitle: "Herdr core documentation",
                                                   workingDirectory: "~/Code/p")

    @Test(arguments: [CoreFixture.socket, "/Users/u/.local/state/herdr-core/work/work.sock"])
    func happyPath(socket: String) async {
        let world = CoreWorld()
        let query = FakeCoreQuery(.reply(CoreFixture.response()), clock: world.clock)
        let lookup = await world.provider(query).lookup(CoreFixture.match(socket: socket), includeDetails: true)
        #expect(lookup == .init(herdrAppURL: CoreFixture.app, details: Self.expected))
        let calls = await query.calls
        #expect(calls.count == 1)
        #expect(calls.first?.terminal == "t5")
        #expect(calls.first?.socket == socket)
    }

    @Test func detailsOffKeepsIconWithoutQueryingCore() async {
        let world = CoreWorld()
        let query = FakeCoreQuery(.reply(CoreFixture.response()), clock: world.clock)
        let lookup = await world.provider(query).lookup(CoreFixture.match(), includeDetails: false)
        #expect(lookup == .init(herdrAppURL: CoreFixture.app, details: nil))
        #expect(await query.calls.isEmpty)
    }

    @Test func unverifiedHolderIsNil() async {
        let world = CoreWorld()
        let query = FakeCoreQuery(.reply(CoreFixture.response()), clock: world.clock)
        #expect(await world.provider(query, verifier: .init(holderVerified: false)).lookup(CoreFixture.match(), includeDetails: true) == nil)
        #expect(await query.calls.isEmpty)
    }

    @Test func appMissingOrUnverifiedStillRecognized() async {
        let world = CoreWorld()
        let query = FakeCoreQuery(.reply(CoreFixture.response()), clock: world.clock)
        let lookup = await world.provider(query, verifier: .init(appURL: nil)).lookup(CoreFixture.match(), includeDetails: true)
        #expect(lookup == .init(herdrAppURL: nil, details: Self.expected))
    }

    @Test func slowAppCheckDoesNotBlockDetails() async {
        let world = CoreWorld()
        let verifier = FakeCoreVerifier(blocksAppCheck: true)
        let query = FakeCoreQuery(.reply(CoreFixture.response()), clock: world.clock)
        // The deadline "passes" only once the app check is stuck; the instant holder check has long finished by then.
        let lookup = await world.provider(query, verifier: verifier, sleep: { _ in
            while !verifier.isBlocked { await Task.yield() }
            try await Task.sleep(for: .milliseconds(50))
        }).lookup(CoreFixture.match(), includeDetails: true)
        #expect(lookup == .init(herdrAppURL: nil, details: Self.expected))
        verifier.unblock()
    }

    @Test(arguments: ["pid", "address", "finished", "chainChanged", "socketChanged", "socketOwner", "relativeSocket", "longSocket"])
    func ownershipFailures(_ scenario: String) async {
        let world = CoreWorld()
        var match = CoreFixture.match()
        var response = CoreFixture.response()
        switch scenario {
        case "pid": response = CoreFixture.response(pid: 99)
        case "address": response = CoreFixture.response(address: "t6")
        case "finished": response = CoreFixture.response(state: "finished")
        case "socketOwner": world.socket.withLock { $0 = .init(device: 1, inode: 2, owner: getuid() &+ 1) }
        case "relativeSocket": match = CoreFixture.match(socket: "relative.sock")
        case "longSocket": match = CoreFixture.match(socket: "/" + String(repeating: "s", count: 200))
        default: break
        }
        let query = FakeCoreQuery(.reply(response), clock: world.clock)
        if scenario == "chainChanged" {
            await query.setOnQuery { world.processes.withLock { $0[12] = CoreFixture.node(12, "/bin/zsh", parent: 99) } }
        }
        if scenario == "socketChanged" {
            await query.setOnQuery { world.socket.withLock { $0 = .init(device: 1, inode: 3, owner: getuid()) } }
        }
        let lookup = await world.provider(query).lookup(match, includeDetails: true)
        #expect(lookup == .init(herdrAppURL: CoreFixture.app, details: nil))
    }

    @Test(arguments: [HerdrCoreSocketError.peerNotCore, .ioFailed, .responseTooLarge])
    func queryErrorsFallBack(_ error: HerdrCoreSocketError) async {
        let world = CoreWorld()
        let query = FakeCoreQuery(.fail(error), clock: world.clock)
        #expect(await world.provider(query).lookup(CoreFixture.match(), includeDetails: true) == .init(herdrAppURL: CoreFixture.app, details: nil))
    }

    @Test func lateReplyFallsBack() async {
        let world = CoreWorld()
        let query = FakeCoreQuery(.late(CoreFixture.response()), clock: world.clock)
        #expect(await world.provider(query).lookup(CoreFixture.match(), includeDetails: true)?.details == nil)
    }

    @Test func cancellationReturnsWithoutDetails() async {
        let world = CoreWorld()
        let query = FakeCoreQuery(.gated, clock: world.clock)
        let provider = world.provider(query)
        let task = Task { await provider.lookup(CoreFixture.match(), includeDetails: true) }
        await query.started()
        task.cancel()
        #expect(await task.value?.details == nil)
        #expect(await query.cancellationObserved)
    }
}

// MARK: - Live socket client

nonisolated private final class TestListener: Sendable {
    let path: String
    private let fd: Int32
    let received = OSAllocatedUnfairLock(initialState: Data())
    let sawEOF = OSAllocatedUnfairLock(initialState: false)

    init(reply: Data?, closeAfterReply: Bool = false) throws {
        path = NSTemporaryDirectory() + "hc-\(UUID().uuidString.prefix(8)).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = SSHAgentConstants.makeUnixAddr(path: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 1) == 0 else { throw HerdrCoreSocketError.connectFailed }
        let listener = fd
        Thread.detachNewThread { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { sawEOF.withLock { $0 = true }; return }
                let chunk = Data(buffer[..<count])
                received.withLock { $0.append(chunk) }
                if chunk.contains(UInt8(ascii: "\n")), let reply {
                    _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
                    if closeAfterReply { return }
                }
            }
        }
    }

    func cleanUp() {
        close(fd)
        unlink(path)
    }
}

@Suite(.timeLimit(.minutes(1)), .serialized)
struct HerdrCoreSocketClientTests {
    private func client(peerVerified: Bool) -> LiveHerdrCoreSocketClient {
        LiveHerdrCoreSocketClient(verifier: FakeCoreVerifier(peerVerified: peerVerified))
    }
    private var deadline: CLIExecutionDeadline { .init(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) }

    @Test func requestLineIsExact() throws {
        #expect(String(decoding: try LiveHerdrCoreSocketClient.requestLine(terminalID: "t5"), as: UTF8.self)
            == #"{"jsonrpc":"2.0","id":1,"method":"terminal.get","params":{"terminal":"t5"}}"# + "\n")
        #expect(String(decoding: try LiveHerdrCoreSocketClient.requestLine(terminalID: #"a"b/c"#), as: UTF8.self)
            .contains(#""terminal":"a\"b/c""#))
    }

    @Test func socketClientRejectsNonCorePeer() async throws {
        let listener = try TestListener(reply: CoreFixture.response() + Data("\n".utf8)); defer { listener.cleanUp() }
        await #expect(throws: HerdrCoreSocketError.peerNotCore) {
            try await client(peerVerified: false).terminalGet(socketPath: listener.path, terminalID: "t5", deadline: deadline)
        }
        while !listener.sawEOF.withLock({ $0 }) { await Task.yield() }
        #expect(listener.received.withLock { $0.isEmpty })
    }

    @Test func socketClientSendsRequestAndReadsLine() async throws {
        let listener = try TestListener(reply: CoreFixture.response() + Data("\n{\"next\":1}\n".utf8)); defer { listener.cleanUp() }
        let data = try await client(peerVerified: true).terminalGet(socketPath: listener.path, terminalID: "t5", deadline: deadline)
        #expect(data == CoreFixture.response())
        #expect(listener.received.withLock { $0 } == (try LiveHerdrCoreSocketClient.requestLine(terminalID: "t5")))
    }

    @Test func replyEndingAtCloseIsAccepted() async throws {
        let listener = try TestListener(reply: CoreFixture.response(), closeAfterReply: true); defer { listener.cleanUp() }
        let data = try await client(peerVerified: true).terminalGet(socketPath: listener.path, terminalID: "t5", deadline: deadline)
        #expect(data == CoreFixture.response())
    }

    @Test func slowPeerCheckTimesOutBeforeWriting() async throws {
        let listener = try TestListener(reply: CoreFixture.response() + Data("\n".utf8)); defer { listener.cleanUp() }
        let verifier = FakeCoreVerifier(blocksPeerCheck: true)
        let client = LiveHerdrCoreSocketClient(verifier: verifier, sleep: { _ in
            while !verifier.isBlocked { await Task.yield() }
        })
        await #expect(throws: CLIError.self) {
            try await client.terminalGet(socketPath: listener.path, terminalID: "t5", deadline: deadline)
        }
        verifier.unblock()
        while !listener.sawEOF.withLock({ $0 }) { await Task.yield() }
        #expect(listener.received.withLock { $0.isEmpty })
    }

    @Test func oversizedReplyThrows() async throws {
        let listener = try TestListener(reply: Data(repeating: UInt8(ascii: "x"), count: 600 * 1024)); defer { listener.cleanUp() }
        await #expect(throws: HerdrCoreSocketError.responseTooLarge) {
            try await client(peerVerified: true).terminalGet(socketPath: listener.path, terminalID: "t5", deadline: deadline)
        }
    }

    @Test func socketClientCancellationDoesNotLeakFd() async throws {
        let listener = try TestListener(reply: nil); defer { listener.cleanUp() }
        let path = listener.path
        let client = client(peerVerified: true)
        let deadline = deadline
        let task = Task { try await client.terminalGet(socketPath: path, terminalID: "t5", deadline: deadline) }
        while !listener.received.withLock({ $0.contains(UInt8(ascii: "\n")) }) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        while !listener.sawEOF.withLock({ $0 }) { await Task.yield() }
    }
}
