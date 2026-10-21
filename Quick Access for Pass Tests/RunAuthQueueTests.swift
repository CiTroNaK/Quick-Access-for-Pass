import Foundation
import Testing
@testable import Quick_Access_for_Pass

@MainActor
@Suite("Run auth queue", .timeLimit(.minutes(1)))
struct RunAuthQueueTests {
    private let connection = VerifiedConnection(
        fd: -1, identity: .signedApp(bundleID: "com.test.app", teamID: "TEAM"), pid: -1
    )

    private func start(
        _ controller: RunAuthWindowController, command: [String]
    ) async -> Task<RunProxyResponse, Never> {
        // The signal resumes the test only after this MainActor turn reaches authorize's
        // continuation suspension; the request is then either completed or truly queued.
        let channel = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            channel.continuation.yield(())
            return await controller.authorize(
                request: RunProxyRequest(profile: "work", command: command, pid: -1),
                profileName: "Work", env: ["TOKEN": "secret"], connection: connection
            )
        }
        var started = channel.stream.makeAsyncIterator()
        _ = await started.next()
        return task
    }

    // Each test gets its own fixture; no cross-test mutable state.
    @MainActor private final class PromptRecorder { var count = 0 }

    @MainActor private final class Fixture {
        let db: DatabaseManager
        let controller: RunAuthWindowController
        let stream: AsyncStream<RunAuthRequest>
        let recorder = PromptRecorder()

        init() throws {
            db = try DatabaseManager(inMemory: true, passphrase: Data("test".utf8))
            let channel = AsyncStream<RunAuthRequest>.makeStream()
            stream = channel.stream
            let recorder = self.recorder
            controller = RunAuthWindowController(
                databaseManager: db, keychainService: FakeBiometricAuthorizer(outcome: .success(())),
                callbacks: .noop, dialogPresenter: {
                    recorder.count += 1
                    channel.continuation.yield($0)
                }
            )
        }
    }

    @Test(arguments: [false, true], [RememberDuration.forever, .doNotRemember, .oneMinute])
    func identicalQueuedRequestsUseOnePrompt(allowed: Bool, duration: RememberDuration) async throws {
        let fixture = try Fixture()
        var prompts = fixture.stream.makeAsyncIterator()
        let first = await start(fixture.controller, command: ["gh", "--version"])
        let prompt = try #require(await prompts.next())
        let second = await start(fixture.controller, command: ["gh", "--version"])
        let exact = try #require(prompt.scopeOptions.first)
        #expect(exact.isExact)
        #expect(prompt.scopeOptions.count == 1)
        prompt.onResult(allowed, duration, exact.identity)
        for task in [first, second] {
            let response = await task.value
            #expect(response.decision == (allowed ? .allow : .deny))
            #expect(response.env == (allowed ? ["TOKEN": "secret"] : nil))
        }
        #expect(fixture.recorder.count == 1)
        let rows = try fixture.db.allRunAuthDecisions()
        #expect(rows.map(\.matchValue) == (duration == .doNotRemember ? [] : [exact.identity.matchValue]))
        if duration != .doNotRemember {
            let presentation = RunAuthDecisionRowPresentation(decision: try #require(rows.first), profileName: "Work")
            #expect(presentation.primaryText == "gh --version")
            #expect(presentation.scopeHelpText == "gh --version")
            #expect(rows.first?.allowed == allowed)
        }
        if duration == .forever { #expect(rows.first?.expiresAt == nil) }
        if duration == .oneMinute { #expect(try #require(rows.first?.expiresAt) > Date()) }
    }

    @Test(arguments: [["gh", "--version"], ["/usr/bin/gh", "--version"], ["gh", "pr", "list", "--limit", "5"]])
    func changedVectorGetsItsOwnPrompt(command: [String]) async throws {
        let fixture = try Fixture()
        var prompts = fixture.stream.makeAsyncIterator()
        let first = await start(fixture.controller, command: command)
        let prompt = try #require(await prompts.next())
        let second = await start(fixture.controller, command: command + ["--other"])
        let exact = try #require(prompt.scopeOptions.first)
        #expect(exact.isExact)
        #expect(prompt.command == command.joined(separator: " "))
        prompt.onResult(true, .forever, exact.identity)
        #expect(await first.value.decision == .allow)
        let changed = try #require(await prompts.next())
        #expect(changed.scopeOptions.first?.isExact == true)
        #expect(changed.scopeOptions.first?.identity != exact.identity)
        changed.onResult(false, .forever, changed.scopeOptions.first?.identity)
        let response = await second.value
        #expect(response.decision == .deny)
        #expect(response.env == nil)
        #expect(fixture.recorder.count == 2)
        #expect(try fixture.db.allRunAuthDecisions().count == 2)
    }

    @Test(arguments: [false, true])
    func explicitBroaderSelectionStillMatchesChangedArguments(allowed: Bool) async throws {
        let fixture = try Fixture()
        var prompts = fixture.stream.makeAsyncIterator()
        let first = await start(fixture.controller, command: ["gh", "pr", "list", "--limit", "5"])
        let prompt = try #require(await prompts.next())
        #expect(prompt.scopeOptions.map(\.identity.matchValue).dropFirst() == ["gh pr list", "gh pr"])
        let second = await start(fixture.controller, command: ["gh", "pr", "list", "--limit", "6"])
        prompt.onResult(allowed, .forever, RunAuthorizationIdentity(prefix: "gh pr list"))
        for task in [first, second] {
            let response = await task.value
            #expect(response.decision == (allowed ? .allow : .deny))
            #expect(response.env == (allowed ? ["TOKEN": "secret"] : nil))
        }
        #expect(fixture.recorder.count == 1)
        #expect(try fixture.db.allRunAuthDecisions().map(\.matchValue) == ["gh pr list"])
    }

    @Test func queueRecheckPrefersExactDenialToBroaderSessionApproval() async throws {
        let fixture = try Fixture()
        var prompts = fixture.stream.makeAsyncIterator()
        let first = await start(fixture.controller, command: ["gh", "pr", "view"])
        let prompt = try #require(await prompts.next())
        let secondCommand = ["gh", "pr", "list", "--limit", "5"]
        let second = await start(fixture.controller, command: secondCommand)
        let exact = try #require(RunAuthorizationScope.exact(command: secondCommand))
        try fixture.db.saveRunDecision(appIdentifier: "TEAM.com.test.app", scope: exact,
                                       profileSlug: "work", expiresAt: nil, allowed: false)
        fixture.controller.storeSessionCache(appIdentifier: "TEAM.com.test.app", profileSlug: "work",
                                             scope: RunAuthorizationIdentity(prefix: "gh pr"), allowed: true)
        prompt.onResult(true, .doNotRemember, prompt.scopeOptions.first?.identity)
        #expect(await first.value.decision == .allow)
        let response = await second.value
        #expect(response.decision == .deny)
        #expect(response.env == nil)
        #expect(fixture.recorder.count == 1)
    }

    @Test func cancelledAndDuplicateCompletionsCannotMutateAnotherRequest() async throws {
        let fixture = try Fixture()
        var prompts = fixture.stream.makeAsyncIterator()
        let cancelled = await start(fixture.controller, command: ["gh", "--version"])
        let stale = try #require(await prompts.next())
        let queued = await start(fixture.controller, command: ["gh", "--version"])
        fixture.controller.cancelAll()
        #expect(await cancelled.value.decision == .deny)
        #expect(await queued.value.env == nil)
        let live = await start(fixture.controller, command: ["/usr/bin/gh", "--version"])
        let prompt = try #require(await prompts.next())
        stale.onResult(true, .forever, stale.scopeOptions.first?.identity)
        #expect(try fixture.db.allRunAuthDecisions().isEmpty)
        #expect(fixture.controller.sessionCache.isEmpty)
        prompt.onResult(false, .forever, prompt.scopeOptions.first?.identity)
        let response = await live.value
        #expect(response.decision == .deny)
        #expect(response.env == nil)
        prompt.onResult(true, .forever, prompt.scopeOptions.first?.identity)
        stale.onResult(true, .forever, stale.scopeOptions.first?.identity)
        let rows = try fixture.db.allRunAuthDecisions()
        #expect(rows.count == 1)
        #expect(rows.first?.allowed == false)
        #expect(fixture.controller.sessionCache.count == 1)
        #expect(fixture.controller.sessionCache.values.first?.allowed == false)
    }

    @Test(arguments: ["gh pr", "exact-v1:invalid", "unoffered"])
    func unofferedScopeNeverCachedOrPersisted(key: String) async throws {
        let fixture = try Fixture()
        var prompts = fixture.stream.makeAsyncIterator()
        let task = await start(fixture.controller, command: ["gh", "--version"])
        let prompt = try #require(await prompts.next())
        prompt.onResult(false, .forever, RunAuthorizationIdentity(prefix: key))
        #expect(await task.value.env == nil)
        #expect(try fixture.db.allRunAuthDecisions().isEmpty)
        #expect(fixture.controller.sessionCache.isEmpty)
    }
}
