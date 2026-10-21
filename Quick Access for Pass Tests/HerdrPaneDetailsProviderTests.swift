import Darwin
import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

nonisolated private enum HerdrFixture {
    static let socket = HerdrSocketIdentity(device: 1, inode: 2, owner: getuid())
    static func node(_ pid: Int32, parent: Int32, start: UInt64 = 100) -> RequesterProcessSnapshot.ProcessNode {
        .init(pid: pid, parentPID: parent, startTimeMicroseconds: start,
              executablePath: "/fixture/process-\(pid)", canonicalExecutablePath: "/fixture/process-\(pid)")
    }
    static func match(pane: String? = "p1", hint: Bool = true) -> TerminalHostMatch {
        .init(configurationID: "fixture", executablePath: "/fixture/herdr", host: node(30, parent: 1),
              requesterSideNodes: [node(10, parent: 20), node(20, parent: 30)],
              routingHint: hint ? .init(socketPath: "/fixture/requester.sock", paneID: pane,
                                       originatingPID: 20, originatingStartTimeMicroseconds: 100) : nil)
    }
    static func snapshot(count: Int = 2, moved: Bool = false, missingLabels: Bool = false) -> Data {
        let panes: [[String: Any]] = (1...max(1, count)).map { index in
            var pane: [String: Any] = ["pane_id": "p\(index)", "tab_id": moved ? "t2" : "t1", "workspace_id": "w1", "focused": index == 2]
            if missingLabels == false {
                pane["terminal_title_stripped"] = "\u{1b}[31mBuild\u{1b}[0m\n\u{7}"
                pane["foreground_cwd"] = "/fixture/home/project"
            }
            // Unknown fields must never be retained or used as identity.
            pane["unknown_metadata"] = ["synthetic": true]
            return pane
        }
        let labels: [String: Any] = missingLabels ? [:] : ["label": "Workspace"]
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": "fixture", "result": ["type": "session_snapshot", "snapshot": [
            "protocol": 22, "version": "fixture", "workspaces": [["workspace_id": "w1"].merging(labels) { a, _ in a }],
            "tabs": [["tab_id": "t1", "workspace_id": "w1"].merging(missingLabels ? [:] : ["label": "Tab"]) { a, _ in a },
                     ["tab_id": "t2", "workspace_id": "w1"]], "panes": count == 0 ? [] : panes,
            "agents": [], "layouts": [], "focused_pane_id": "p2"
        ]]]) else { preconditionFailure("Invalid synthetic JSON fixture") }
        return data
    }
    static func finalSnapshot(_ scenario: String) throws -> Data {
        if scenario == "final-added" || scenario == "final-added-second-match" { return snapshot(count: 3) }
        if scenario == "final-removed-other" { return snapshot(count: 1) }
        var object = try #require(try JSONSerialization.jsonObject(with: snapshot()) as? [String: Any])
        var result = try #require(object["result"] as? [String: Any])
        var metadata = try #require(result["snapshot"] as? [String: Any])
        var panes = try #require(metadata["panes"] as? [[String: Any]])
        var tabs = try #require(metadata["tabs"] as? [[String: Any]])
        var workspaces = try #require(metadata["workspaces"] as? [[String: Any]])
        switch scenario {
        case "final-other-tab":
            panes[1]["tab_id"] = "t2"
        case "final-other-workspace":
            workspaces.append(["workspace_id": "w2"])
            tabs.append(["tab_id": "t3", "workspace_id": "w2"])
            panes[1]["workspace_id"] = "w2"
            panes[1]["tab_id"] = "t3"
        case "final-display-update", "final-reordered-display-update":
            workspaces[0]["label"] = "Fresh Workspace"
            tabs[0]["label"] = "Fresh Tab"
            panes[0]["terminal_title_stripped"] = "Fresh Title"
            panes[0]["foreground_cwd"] = "/fixture/home/fresh"
        default: break
        }
        if scenario == "final-reordered" || scenario == "final-reordered-display-update" {
            panes.reverse()
            tabs.reverse()
            workspaces.reverse()
        }
        metadata["panes"] = panes; metadata["tabs"] = tabs; metadata["workspaces"] = workspaces
        result["snapshot"] = metadata; object["result"] = result
        return try JSONSerialization.data(withJSONObject: object)
    }
    static func process(_ id: String, pid: String = "20") -> Data {
        Data("{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"\(id)\",\"shell_pid\":\(pid)}}}".utf8)
    }
}

/// Synthetic elapsed time is independent of full-suite scheduler contention.
private nonisolated final class HerdrFixtureClock: Sendable {
    static let start: UInt64 = 10_000_000_000
    private let ticks = OSAllocatedUnfairLock(initialState: start)
    var now: UInt64 { ticks.withLock { $0 } }
    func advance(by elapsed: UInt64) { ticks.withLock { $0 += elapsed } }
}

private actor HerdrFixtureRunner {
    struct Call: Sendable {
        let path: String
        let args: [String]
        let env: [String: String]
        let deadline: CLIExecutionDeadline
        let limit: Int
    }
    let clock = HerdrFixtureClock()
    var calls: [Call] = []
    var active = 0
    var maximumActive = 0
    var cancelled = 0
    let scenario: String
    init(_ scenario: String = "success") { self.scenario = scenario }
    // pi-lens-ignore: cyclomatic_complexity
    func run(_ path: String, _ args: [String], _ env: [String: String], _ deadline: CLIExecutionDeadline, _ limit: Int) async throws -> Data {
        calls.append(.init(path: path, args: args, env: env, deadline: deadline, limit: limit))
        let snapshots = calls.filter { $0.args == ["api", "snapshot"] }.count
        if args == ["api", "snapshot"] {
            if scenario == "malformed" { return Data("not-json".utf8) }
            if scenario == "unsupported" { return Data("{\"result\":{\"type\":\"other\"}}".utf8) }
            if scenario == "overflow" { return Data(repeating: 0, count: limit + 1) }
            if scenario == "timeout" { throw CLIError.timeout }
            if scenario == "late-return" { clock.advance(by: 750_000_001) }
            if scenario == "over-limit" { return HerdrFixture.snapshot(count: 33) }
            if scenario == "at-limit" { return HerdrFixture.snapshot(count: 32) }
            if scenario == "concurrency" || scenario == "cancel" || scenario == "failed-scan" { return HerdrFixture.snapshot(count: 8) }
            if scenario == "moved" && snapshots == 2 { return HerdrFixture.snapshot(moved: true) }
            if scenario == "closed" && snapshots == 2 { return HerdrFixture.snapshot(count: 0) }
            if scenario.hasPrefix("final-") && snapshots == 2 { return try HerdrFixture.finalSnapshot(scenario) }
            return HerdrFixture.snapshot(missingLabels: scenario == "missing-labels")
        }
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if scenario == "failed-scan" && args.last == "p2" {
            while active < 4 { await Task.yield() }
            throw CLIError.commandFailed("synthetic failure")
        }
        if scenario == "cancel" || (scenario == "failed-scan" && args.last != "p1") {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled += 1; throw error }
        }
        if scenario == "concurrency" { try await Task.sleep(for: .milliseconds(5)) }
        let id = try #require(args.last)
        if scenario == "mismatch" { return HerdrFixture.process("not-in-snapshot") }
        if scenario == "closed-process" && id == "p1" { throw CLIError.commandFailed("synthetic closed pane") }
        if scenario == "ambiguous" || (scenario == "final-added-second-match" && id == "p3") { return HerdrFixture.process(id) }
        if scenario == "wrong-session" { return HerdrFixture.process(id, pid: "90") }
        if scenario == "host-pid" { return HerdrFixture.process(id, pid: "30") }
        if scenario == "positive-plus-null" && id == "p2" { return HerdrFixture.process(id, pid: "null") }
        if scenario == "positive-plus-missing" && id == "p2" {
            return Data("{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"p2\"}}}".utf8)
        }
        if scenario == "missing-pid" { return Data("{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"\(id)\"}}}".utf8) }
        if ["null", "0", "2147483648", "4294967295", "18446744073709551616", "-1", "1.5"].contains(scenario) { return HerdrFixture.process(id, pid: scenario) }
        return HerdrFixture.process(id, pid: id == "p1" ? "20" : "90")
    }
    func waitForChildren() async {
        while active < 4 { await Task.yield() }
    }
}

struct HerdrPaneDetailsProviderTests {
    private func provider(_ runner: HerdrFixtureRunner,
                          node: @escaping @Sendable (pid_t) -> RequesterProcessSnapshot.ProcessNode? = { pid in
                              [HerdrFixture.node(10, parent: 20), HerdrFixture.node(20, parent: 30), HerdrFixture.node(30, parent: 1)].first { $0.pid == pid }
                          },
                          socket: @escaping @Sendable (String) -> HerdrSocketIdentity? = { _ in HerdrFixture.socket }) -> LiveHerdrPaneDetailsProvider {
        .init(runCommand: { try await runner.run($0, $1, $2, $3, $4) }, readProcess: node, readSocket: socket,
              inheritedEnvironmentKeys: { ["HERDR_PANE_ID", "HERDR_FUTURE_ROUTING", "UNRELATED"] },
              homeDirectory: "/fixture/home", now: { runner.clock.now })
    }

    @Test func exactShellPIDWinsOverFocusAndStaleHintWithOneAbsoluteBudget() async throws {
        let runner = HerdrFixtureRunner()
        let details = try #require(await provider(runner).details(for: HerdrFixture.match(pane: "p2")))
        #expect(details == .init(workspaceLabel: "Workspace", tabLabel: "Tab", paneTitle: "Build", workingDirectory: "~/project"))
        let calls = await runner.calls
        #expect(calls.count == 4)
        #expect(calls.first?.args == ["api", "snapshot"])
        #expect(calls.filter { $0.args.first == "pane" }.first?.args.last == "p2")
        #expect(Set(calls.map { $0.deadline.uptimeNanoseconds }).count == 1)
        for call in calls {
            #expect(call.path == "/fixture/herdr")
            #expect(call.limit == 512 * 1024)
            #expect(call.env["HERDR_SOCKET_PATH"] == "/fixture/requester.sock")
            for key in ["HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID", "HERDR_SESSION",
                        "HERDR_MACHINE", "HERDR_REMOTE", "HERDR_CONFIG_PATH",
                        "HERDR_BIN_PATH", "HERDR_ENV", "HERDR_FUTURE_ROUTING"] {
                #expect(call.env[key] == "")
            }
            #expect(call.env["UNRELATED"] == nil)
            #expect(call.args == ["api", "snapshot"] || (call.args.count == 4 && Array(call.args.prefix(3)) == ["pane", "process-info", "--pane"]))
        }
        #expect(calls.allSatisfy { $0.deadline.uptimeNanoseconds == HerdrFixtureClock.start + 750_000_000 })
    }

    @Test(arguments: ["ambiguous", "positive-plus-null", "positive-plus-missing", "wrong-session", "host-pid", "mismatch", "closed-process",
                      "missing-pid", "null", "0", "2147483648", "4294967295",
                      "18446744073709551616", "-1",
                      "1.5", "malformed", "unsupported", "overflow", "timeout", "late-return", "over-limit", "moved", "closed"])
    func unsafeOrIncompleteResultsFallBack(_ scenario: String) async {
        let runner = HerdrFixtureRunner(scenario)
        #expect(await provider(runner).details(for: HerdrFixture.match()) == nil)
    }

    @Test(arguments: ["final-added", "final-added-second-match", "final-removed-other", "final-other-tab", "final-other-workspace"])
    func changedFinalCandidateAssociationsFallBackWithoutRescanning(_ scenario: String) async throws {
        let runner = HerdrFixtureRunner(scenario)
        #expect(await provider(runner).details(for: HerdrFixture.match()) == nil)
        await assertOriginalScanAndBudget(runner)
        // The new candidate would match ancestry if inspected, but a changed set must never trigger a rescan.
        if scenario == "final-added-second-match" {
            #expect(try HerdrMetadataDecoder.shellPID(HerdrFixture.process("p3"), requestedPaneID: "p3") == 20)
        }
    }

    @Test(arguments: ["final-reordered", "final-display-update", "final-reordered-display-update"])
    func stableFinalCandidateAssociationsPublishFreshDisplayMetadata(_ scenario: String) async throws {
        let runner = HerdrFixtureRunner(scenario)
        let details = try #require(await provider(runner).details(for: HerdrFixture.match()))
        let updated = scenario != "final-reordered"
        #expect(details == .init(workspaceLabel: updated ? "Fresh Workspace" : "Workspace",
                                tabLabel: updated ? "Fresh Tab" : "Tab", paneTitle: updated ? "Fresh Title" : "Build",
                                workingDirectory: updated ? "~/fresh" : "~/project"))
        await assertOriginalScanAndBudget(runner)
    }

    private func assertOriginalScanAndBudget(_ runner: HerdrFixtureRunner) async {
        let calls = await runner.calls
        #expect(calls.count == 4)
        #expect(calls.filter { $0.args == ["api", "snapshot"] }.count == 2)
        #expect(Set(calls.filter { $0.args.first == "pane" }.compactMap { $0.args.last }) == Set(["p1", "p2"]))
        #expect(calls.first?.args == ["api", "snapshot"])
        #expect(calls.last?.args == ["api", "snapshot"])
        #expect(calls.allSatisfy { $0.deadline.uptimeNanoseconds == HerdrFixtureClock.start + 750_000_000 })
        #expect(calls.allSatisfy { $0.limit == 512 * 1024 })
        #expect(await runner.maximumActive <= 4)
    }

    @Test func elapsedOriginalBudgetRejectsBeforeLaunchAndAfterLateReturn() async {
        let beforeLaunch = HerdrFixtureRunner()
        let sut = provider(beforeLaunch, node: { pid in
            beforeLaunch.clock.advance(by: 750_000_001)
            return HerdrFixture.node(pid, parent: pid == 10 ? 20 : pid == 20 ? 30 : 1)
        })
        #expect(await sut.details(for: HerdrFixture.match()) == nil)
        #expect(await beforeLaunch.calls.isEmpty)
        let late = HerdrFixtureRunner("late-return")
        #expect(await provider(late).details(for: HerdrFixture.match()) == nil)
        let calls = await late.calls
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { $0.deadline.uptimeNanoseconds == HerdrFixtureClock.start + 750_000_000 })
    }

    @Test func missingOptionalFieldsAreNotInferredFromFocus() async {
        let runner = HerdrFixtureRunner("missing-labels")
        #expect(await provider(runner).details(for: HerdrFixture.match()) == .init(workspaceLabel: nil, tabLabel: nil, paneTitle: nil, workingDirectory: nil))
    }

    @Test(arguments: ["exit", "reuse", "parent", "host-exit"])
    func processRevalidationFailsClosed(_ scenario: String) async {
        let runner = HerdrFixtureRunner()
        let sut = provider(runner, node: { pid in
            if scenario == "exit" && pid == 20 || scenario == "host-exit" && pid == 30 { return nil }
            if pid == 20 { return HerdrFixture.node(20, parent: scenario == "parent" ? 99 : 30, start: scenario == "reuse" ? 101 : 100) }
            return HerdrFixture.node(pid, parent: pid == 10 ? 20 : 1)
        })
        #expect(await sut.details(for: HerdrFixture.match()) == nil)
    }

    @Test func replacedSocketAndLateProcessExitRejectPublication() async {
        for lateProcessExit in [false, true] {
            let runner = HerdrFixtureRunner()
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let sut = provider(runner, node: { pid in
                if lateProcessExit && reads.withLock({ $0 >= 2 }) && pid == 20 { return nil }
                return HerdrFixture.node(pid, parent: pid == 10 ? 20 : pid == 20 ? 30 : 1)
            }, socket: { _ in
                reads.withLock { value in
                    value += 1
                    return value == 1 || lateProcessExit ? HerdrFixture.socket : .init(device: 1, inode: 3, owner: getuid())
                }
            })
            #expect(await sut.details(for: HerdrFixture.match()) == nil)
        }
    }

    @Test func missingConflictingOrCrossBoundaryHintNeverRunsCLI() async {
        let runner = HerdrFixtureRunner()
        let base = HerdrFixture.match()
        let outside = TerminalHostMatch(configurationID: base.configurationID, executablePath: base.executablePath, host: base.host,
                                        requesterSideNodes: base.requesterSideNodes,
                                        routingHint: .init(socketPath: "/fixture/socket", paneID: "p1", originatingPID: 30, originatingStartTimeMicroseconds: 100))
        // Resolver represents conflicting origins as nil; host-side origins are forbidden independently.
        #expect(await provider(runner).details(for: HerdrFixture.match(hint: false)) == nil)
        #expect(await provider(runner).details(for: outside) == nil)
        #expect(await provider(runner, socket: { _ in nil }).details(for: base) == nil)
        #expect(await runner.calls.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationAndFailedScanJoinChildren() async {
        for scenario in ["cancel", "failed-scan"] {
            let runner = HerdrFixtureRunner(scenario)
            let sut = provider(runner)
            let task = Task { await sut.details(for: HerdrFixture.match(pane: scenario == "cancel" ? nil : "p1")) }
            if scenario == "cancel" { await runner.waitForChildren(); task.cancel() }
            #expect(await task.value == nil)
            #expect(await runner.active == 0)
            #expect(await runner.cancelled > 0)
            #expect(await runner.maximumActive <= 4)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelledBeforeAttemptNeverLaunches() async throws {
        let runner = HerdrFixtureRunner()
        let sut = provider(runner)
        let gate = OfflineTestGate()
        let task = Task {
            _ = try? await gate.wait()
            return await sut.details(for: HerdrFixture.match())
        }
        try await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        #expect(await task.value == nil)
        #expect(await runner.calls.isEmpty)
    }

    @Test func completeScanHasAtMostFourChildren() async {
        let runner = HerdrFixtureRunner("concurrency")
        #expect(await provider(runner).details(for: HerdrFixture.match()) != nil)
        #expect(await runner.calls.filter { $0.args.first == "pane" }.count == 8)
        #expect(await runner.maximumActive <= 4)
    }

    @Test func completeScanIncludesThirtyTwoCandidates() async {
        let runner = HerdrFixtureRunner("at-limit")
        #expect(await provider(runner).details(for: HerdrFixture.match()) != nil)
        #expect(await runner.calls.filter { $0.args.first == "pane" }.count == 32)
    }

    @Test func decoderRejectsUnsupportedProtocol() throws {
        for replacement in ["\"protocol\":23", "\"protocol\":0"] {
            var object = try #require(try JSONSerialization.jsonObject(with: HerdrFixture.snapshot()) as? [String: Any])
            var result = try #require(object["result"] as? [String: Any])
            var snapshot = try #require(result["snapshot"] as? [String: Any])
            snapshot["protocol"] = replacement.contains("23") ? 23 : 0
            result["snapshot"] = snapshot; object["result"] = result
            #expect(throws: (any Error).self) { try HerdrMetadataDecoder.snapshot(JSONSerialization.data(withJSONObject: object)) }
        }
    }

    @Test func conflictingCapturedOriginsPreventRoutingThroughResolver() async throws {
        let base = HerdrFixture.match()
        let snapshot = RequesterProcessSnapshot(requester: base.requesterSideNodes[0],
                                                ancestors: [base.requesterSideNodes[1], base.host], routingHints: [
            .init(socketPath: "/fixture/a.sock", paneID: "p1", originatingPID: 10, originatingStartTimeMicroseconds: 100),
            .init(socketPath: "/fixture/b.sock", paneID: "p2", originatingPID: 20, originatingStartTimeMicroseconds: 100)
        ])
        let configuration = TerminalHostConfiguration(id: "fixture", executablePath: base.executablePath, displayName: "Host",
                                                       isEnabled: true, provider: .herdr, showPaneDetails: true, isAutomaticallyDetected: false)
        let client = SSHClientInfo(name: "ssh", bundleIdentifier: nil, bundleURL: nil, command: "synthetic", triggerCommand: nil,
                                   showCommand: false, batchMode: false)
        let result = RequesterPresentationResolver.resolve(clientInfo: client, snapshot: snapshot, entries: [
            .init(configuration: configuration, canonicalExecutablePath: base.host.canonicalExecutablePath)
        ])
        let match = try #require(result.hostMatch)
        #expect(match.routingHint == nil)
        let runner = HerdrFixtureRunner()
        #expect(await provider(runner).details(for: match) == nil)
        #expect(await runner.calls.isEmpty)
    }

    @Test func nestedHostCannotMatchOuterHostShellPID() async {
        let runner = HerdrFixtureRunner()
        let match = TerminalHostMatch(configurationID: "nested", executablePath: "/fixture/herdr",
                                      host: HerdrFixture.node(20, parent: 30), requesterSideNodes: [HerdrFixture.node(10, parent: 20)],
                                      routingHint: .init(socketPath: "/fixture/nested.sock", paneID: "p1",
                                                         originatingPID: 10, originatingStartTimeMicroseconds: 100))
        #expect(await provider(runner).details(for: match) == nil)
    }

    @Test func unownedSocketAndMalformedRoutingNeverLaunch() async {
        let runner = HerdrFixtureRunner()
        #expect(await provider(runner, socket: { _ in .init(device: 1, inode: 2, owner: getuid() + 1) })
            .details(for: HerdrFixture.match()) == nil)
        let base = HerdrFixture.match()
        for path in ["relative.sock", "/bad\n.sock", "/" + String(repeating: "x", count: 200)] {
            let match = TerminalHostMatch(configurationID: base.configurationID, executablePath: base.executablePath,
                                          host: base.host, requesterSideNodes: base.requesterSideNodes,
                                          routingHint: .init(socketPath: path, paneID: "p1", originatingPID: 20, originatingStartTimeMicroseconds: 100))
            #expect(await provider(runner).details(for: match) == nil)
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func liveSocketValidationRejectsMissingFilesSymlinksAndInaccessibleSockets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("local.sock").path
        #expect(HerdrSocketIdentity.read(path) == nil)
        try Data("synthetic".utf8).write(to: URL(fileURLWithPath: path))
        #expect(HerdrSocketIdentity.read(path) == nil)
        try FileManager.default.removeItem(atPath: path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(result == 0)
        let identity = try #require(HerdrSocketIdentity.read(path))
        #expect(identity.owner == getuid())
        let symlink = directory.appendingPathComponent("link.sock").path
        try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: path)
        #expect(HerdrSocketIdentity.read(symlink) == nil)
        #expect(chmod(path, 0) == 0)
        #expect(HerdrSocketIdentity.read(path) == nil)
    }

    @Test func decoderRejectsDuplicateIDsBrokenJoinsAndDangerousPaneSelectors() throws {
        for mutation in ["duplicate-pane", "duplicate-tab", "duplicate-workspace", "unknown-tab", "unknown-workspace", "wrong-tab-workspace", "option-id", "control-id"] {
            var object = try #require(try JSONSerialization.jsonObject(with: HerdrFixture.snapshot()) as? [String: Any])
            var result = try #require(object["result"] as? [String: Any])
            var snapshot = try #require(result["snapshot"] as? [String: Any])
            var panes = try #require(snapshot["panes"] as? [[String: Any]])
            var tabs = try #require(snapshot["tabs"] as? [[String: Any]])
            var workspaces = try #require(snapshot["workspaces"] as? [[String: Any]])
            switch mutation {
            case "duplicate-pane": panes.append(panes[0])
            case "duplicate-tab": tabs.append(tabs[0])
            case "duplicate-workspace": workspaces.append(workspaces[0])
            case "unknown-tab": panes[0]["tab_id"] = "not-present"
            case "unknown-workspace": tabs[0]["workspace_id"] = "not-present"
            case "wrong-tab-workspace": panes[0]["workspace_id"] = "not-present"
            case "option-id": panes[0]["pane_id"] = "--remote"
            default: panes[0]["pane_id"] = "bad\nID"
            }
            snapshot["panes"] = panes; snapshot["tabs"] = tabs; snapshot["workspaces"] = workspaces
            result["snapshot"] = snapshot; object["result"] = result
            #expect(throws: (any Error).self) { try HerdrMetadataDecoder.snapshot(JSONSerialization.data(withJSONObject: object)) }
        }
    }

    @Test func decoderPreservesNullableShellPIDAndCwdFallbackIsMetadataOnly() throws {
        #expect(try HerdrMetadataDecoder.shellPID(HerdrFixture.process("p1", pid: "null"), requestedPaneID: "p1") == nil)
        let snapshot = try HerdrMetadataDecoder.snapshot(HerdrFixture.snapshot())
        let pane = HerdrMetadataDecoder.Pane(paneID: "p1", workspaceID: "w1", tabID: "t1", terminalTitleStripped: nil,
                                             foregroundCWD: nil, cwd: "/fixture/home")
        #expect(snapshot.details(for: pane, homeDirectory: "/fixture/home").workingDirectory == "~")
    }

    @Test func sanitizationBoundsControlsEscapesAndHomeBoundary() {
        #expect(HerdrMetadataDecoder.sanitize("\u{1b}]0;hidden\u{7}OK\u{1b}[32m\n", homeDirectory: "/home") == "OK")
        #expect(HerdrMetadataDecoder.sanitize(String(repeating: "é", count: 300), homeDirectory: "/home")?.count == 256)
        #expect(HerdrMetadataDecoder.sanitize("A\u{2028}B\u{2029}C\u{202e}D", homeDirectory: "/home") == "ABCD")
        #expect(HerdrMetadataDecoder.sanitize("/home-other", homeDirectory: "/home") == "/home-other")
    }
}
