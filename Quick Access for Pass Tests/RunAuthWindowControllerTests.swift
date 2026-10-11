import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite(.timeLimit(.minutes(1))) @MainActor
struct RunAuthWindowControllerTests {
    @Test(arguments: ["rename", "disable", "details"])
    func detachedParentHeaderNeverChangesUnknownAuthorizationIdentity(change: String) async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let database = try DatabaseManager(inMemory: true, passphrase: Data("fixture".utf8))
        let prompts = AsyncStream.makeStream(of: RunAuthRequest.self)
        var headerCalls = 0
        let controller = RunAuthWindowController(
            databaseManager: database, keychainService: FakeBiometricAuthorizer(outcome: .success(())), callbacks: .noop,
            identifyParent: { _ in fixture.client },
            headerFactory: { _ in headerCalls += 1; return fixture.model() },
            dialogPresenter: { prompts.continuation.yield($0) }
        )
        let connection = VerifiedConnection(fd: -1, identity: .trustedHelper, pid: 100)
        let request = RunProxyRequest(profile: "fixture", command: ["git", "fetch"], pid: 100)
        let auth = Task { await controller.authorize(request: request, profileName: "Fixture", env: [:], connection: connection) }
        var iterator = prompts.stream.makeAsyncIterator()
        let prompt = try #require(await iterator.next())
        let model = try #require(prompt.headerModel)
        #expect(model.presentation.name == "Herdr")
        #expect(prompt.appName == "ssh")
        let load = Task { await model.loadDetails() }
        await fixture.provider.started(); await fixture.provider.finish(); await load.value
        #expect(model.presentation.details != nil)
        var entry = try #require(fixture.store.entries.first)
        if change == "rename" { entry.displayName = "Changed display" }
        if change == "disable" { entry.isEnabled = false }
        if change == "details" { entry.showPaneDetails = false }
        try fixture.store.update(entry)
        #expect(model.presentation.details == nil)
        prompt.onResult(true, .forever, RunAuthorizationIdentity(prefix: "git fetch"))
        #expect(await auth.value.decision == .allow)
        #expect(try database.findValidRunDecision(
            appIdentifier: "unknown", identity: RunAuthorizationIdentity(prefix: "git fetch"), profileSlug: "fixture"
        )?.allowed == true)
        #expect(try database.findValidRunDecision(
            appIdentifier: "Changed display", identity: RunAuthorizationIdentity(prefix: "git fetch"), profileSlug: "fixture"
        ) == nil)
        entry.isEnabled = false
        try fixture.store.update(entry)
        #expect(await controller.authorize(request: request, profileName: "Fixture", env: [:], connection: connection).decision == .allow)
        #expect(headerCalls == 1)
        #expect(await fixture.provider.calls == 1)
        controller.cancelAll()
    }

    @Test(arguments: ["cache", "advance", "cancelAll"])
    func queuedRequestsCreateHeadersOnlyWhenDisplayedAndCancelOldModels(outcome: String) async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let database = try DatabaseManager(inMemory: true, passphrase: Data("fixture".utf8))
        let prompts = AsyncStream.makeStream(of: RunAuthRequest.self)
        let identities = AsyncStream.makeStream(of: Int32.self)
        var headers = 0
        let controller = RunAuthWindowController(databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())), callbacks: .noop,
            identifyParent: { connection in
                identities.continuation.yield(connection.pid)
                return fixture.client
            },
            headerFactory: { _ in headers += 1; return fixture.model() },
            dialogPresenter: { prompts.continuation.yield($0) })
        let firstRequest = RunProxyRequest(profile: "fixture", command: ["git", "fetch"], pid: 100)
        let secondRequest = RunProxyRequest(profile: "fixture", command: ["git", outcome == "advance" ? "push" : "fetch"], pid: 200)
        let first = Task { await controller.authorize(request: firstRequest, profileName: "Fixture", env: [:],
            connection: .init(fd: -1, identity: .trustedHelper, pid: 100)) }
        var iterator = prompts.stream.makeAsyncIterator()
        let prompt = try #require(await iterator.next())
        let model = try #require(prompt.headerModel)
        #expect(model.presentation.name == "Herdr")
        let load = Task { await model.loadDetails() }
        await fixture.provider.started()
        let second = Task { await controller.authorize(request: secondRequest, profileName: "Fixture", env: [:],
            connection: .init(fd: -1, identity: .trustedHelper, pid: 200)) }
        var identified = identities.stream.makeAsyncIterator()
        while await identified.next() != 200 { }
        #expect(headers == 1)
        if outcome == "cancelAll" { controller.cancelAll() } else { prompt.onResult(false, .doNotRemember, RunAuthorizationIdentity(prefix: "git fetch")) }
        #expect(await first.value.decision == .deny)
        await fixture.provider.finish(); await load.value
        #expect(model.presentation.details == nil)
        if outcome == "advance" {
            let next = try #require(await iterator.next())
            #expect(next.headerModel?.presentation.name == "Herdr")
            #expect(next.headerModel !== model)
            #expect(next.headerModel?.presentation.details == nil)
            #expect(headers == 2)
            controller.cancelAll()
        }
        #expect(await second.value.decision == .deny)
        #expect(headers == (outcome == "advance" ? 2 : 1))
        #expect(await fixture.provider.calls == 1)
        controller.cancelAll()
    }

    @Test func identifiedHelperParentAndSignedAppKeepOriginalAuthorizationIDs() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let database = try DatabaseManager(inMemory: true, passphrase: Data("fixture".utf8))
        let prompts = AsyncStream.makeStream(of: RunAuthRequest.self)
        let appInfo = SSHClientInfo(name: "Fixture App", bundleIdentifier: "com.fixture.Parent", bundleURL: nil,
            command: nil, triggerCommand: nil, showCommand: false, batchMode: false, requesterSnapshot: fixture.client.requesterSnapshot)
        var parentCalls = 0
        let controller = RunAuthWindowController(databaseManager: database,
            keychainService: FakeBiometricAuthorizer(outcome: .success(())), callbacks: .noop,
            identifyParent: { _ in parentCalls += 1; return appInfo },
            headerFactory: { info in RequesterHeaderModel(clientInfo: info, snapshot: info.requesterSnapshot,
                store: fixture.store, detailsProvider: fixture.detailsProvider) },
            dialogPresenter: { prompts.continuation.yield($0) })
        var iterator = prompts.stream.makeAsyncIterator()
        let request = RunProxyRequest(profile: "fixture", command: ["git", "fetch"], pid: 100)
        let helper = Task { await controller.authorize(request: request, profileName: "Fixture", env: [:],
            connection: .init(fd: -1, identity: .trustedHelper, pid: 100)) }
        let prompt = try #require(await iterator.next())
        #expect(prompt.headerModel?.presentation.name == "Fixture App")
        #expect(prompt.headerModel?.reservesDetailRows == false)
        prompt.onResult(true, .forever, RunAuthorizationIdentity(prefix: "git fetch"))
        #expect(await helper.value.decision == .allow)
        #expect(try database.findValidRunDecision(
            appIdentifier: "com.fixture.Parent", identity: RunAuthorizationIdentity(prefix: "git fetch"), profileSlug: "fixture"
        ) != nil)
        let signed = Task { await controller.authorize(request: request, profileName: "Fixture", env: [:],
            connection: .init(fd: -1, identity: .signedApp(bundleID: "com.fixture.Signed", teamID: "FIXTURETEAM"), pid: 200)) }
        let signedPrompt = try #require(await iterator.next())
        #expect(signedPrompt.headerModel?.presentation.name == "com.fixture.Signed")
        signedPrompt.onResult(true, .forever, RunAuthorizationIdentity(prefix: "git fetch"))
        #expect(await signed.value.decision == .allow)
        #expect(parentCalls == 1)
        let decision = try #require(try database.findValidRunDecision(
            appIdentifier: "FIXTURETEAM.com.fixture.Signed", identity: RunAuthorizationIdentity(prefix: "git fetch"), profileSlug: "fixture"
        ))
        #expect(decision.appTeamID == "FIXTURETEAM")
        #expect(await fixture.provider.calls == 0)
        controller.cancelAll()
    }

    @Test func unverifiedRejectedBeforeIdentityAndHeaderFactories() async throws {
        let database = try DatabaseManager(inMemory: true, passphrase: Data("fixture".utf8))
        var identityCalls = 0
        var headerCalls = 0
        let controller = RunAuthWindowController(
            databaseManager: database, keychainService: FakeBiometricAuthorizer(outcome: .success(())), callbacks: .noop,
            identifyParent: { _ in identityCalls += 1; return .unknown },
            headerFactory: { _ in headerCalls += 1; return nil },
            dialogPresenter: { _ in Issue.record("Unverified requester must not display") }
        )
        let connection = VerifiedConnection(fd: -1, identity: .unverified(pid: 100), pid: 100)
        let result = await controller.authorize(request: .init(profile: "fixture", command: ["git"], pid: 100), profileName: "Fixture", env: [:], connection: connection)
        #expect(result.decision == .deny)
        #expect(identityCalls == 0)
        #expect(headerCalls == 0)
    }
}
