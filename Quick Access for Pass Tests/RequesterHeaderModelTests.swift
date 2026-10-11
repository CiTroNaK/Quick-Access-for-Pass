import Foundation
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite(.timeLimit(.minutes(1))) @MainActor
struct RequesterHeaderModelTests {
    @Test func immediateBaseAndMatchedDetailsOnlyOnce() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = fixture.model()
        #expect(model.presentation.name == "Herdr")
        #expect(model.presentation.details == nil)
        let load = Task { await model.loadDetails() }
        await fixture.provider.started()
        await fixture.provider.finish()
        await load.value
        #expect(model.presentation.details == RequesterHeaderFixture.details)
        await model.loadDetails()
        #expect(await fixture.provider.calls == 1)
        model.cancel()
        #expect(model.presentation.details == nil)
    }

    @Test(arguments: [false, true])
    func configurationDisableClearsAndRejectsLatePublication(afterPublication: Bool) async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = fixture.model()
        let load = Task { await model.loadDetails() }
        await fixture.provider.started()
        if afterPublication { await fixture.provider.finish(); await load.value }
        var entry = try #require(fixture.store.entries.first)
        entry.showPaneDetails = false
        try fixture.store.update(entry)
        #expect(model.presentation.details == nil)
        if !afterPublication { await fixture.provider.finish(); await load.value }
        #expect(model.presentation.details == nil)
        entry.showPaneDetails = true
        try fixture.store.update(entry)
        await model.loadDetails()
        #expect(await fixture.provider.calls == 1)
        model.cancel()
    }

    @Test func initiallyDisabledCanStartFirstAttemptOnEnable() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        var entry = try #require(fixture.store.entries.first)
        entry.isEnabled = false
        try fixture.store.update(entry)
        let model = fixture.model()
        await model.loadDetails()
        #expect(model.presentation.name == "ssh")
        #expect(model.reservesDetailRows)
        #expect(await fixture.provider.calls == 0)
        entry.isEnabled = true
        try fixture.store.update(entry)
        let load = Task { await model.loadDetails() }
        await fixture.provider.started(); await fixture.provider.finish(); await load.value
        #expect(model.presentation.details == RequesterHeaderFixture.details)
        model.cancel()
    }

    @Test(arguments: [false, true])
    func cancellationIsTerminalEvenForUncooperativeProvider(viewTaskCancellation: Bool) async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = fixture.model()
        let load = Task { await model.loadDetails() }
        await fixture.provider.started()
        if viewTaskCancellation { load.cancel() } else { model.cancel(); model.cancel() }
        await fixture.provider.finish(); await load.value
        #expect(model.presentation.details == nil)
        await model.loadDetails()
        #expect(await fixture.provider.calls == 1)
        #expect(await fixture.provider.cancellationObserved)
        model.cancel()
        var entry = try #require(fixture.store.entries.first)
        entry.displayName = "Renamed"
        try fixture.store.update(entry)
        #expect(model.presentation.name == "Herdr")
    }

    @Test(arguments: ["host", "details", "collision", "newMapping"])
    func fixedDetailAllocationKeepsBothDialogsSizedBeforeLateEnable(change: String) async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        var entry = try #require(fixture.store.entries.first)
        if change == "host" { entry.isEnabled = false }
        if change == "details" { entry.showPaneDetails = false }
        try fixture.store.update(entry)
        if change == "collision" || change == "newMapping" {
            struct Envelope: Encodable { let version = 1; let entries: [TerminalHostConfiguration] }
            let generic = TerminalHostConfiguration(id: "custom", executablePath: fixture.executable.path,
                displayName: "Custom", isEnabled: false, provider: .generic, showPaneDetails: false, isAutomaticallyDetected: false)
            fixture.defaults.set(try JSONEncoder().encode(Envelope(entries: change == "collision" ? [entry, generic] : [generic])),
                                 forKey: DefaultsKey.terminalHosts)
        }
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: TerminalHostDiscovery(candidates: { [] }))
        let model = RequesterHeaderModel(clientInfo: fixture.client, snapshot: fixture.client.requesterSnapshot,
                                        store: store, detailsProvider: fixture.detailsProvider)
        #expect(model.reservesDetailRows)
        let before = dialogSizes(model)
        #expect(before.allSatisfy { $0.height < 600 })
        if change == "collision" || change == "newMapping" {
            store.remove(id: "custom")
            store.observeExecutable(at: fixture.executable)
        } else {
            entry.isEnabled = true; entry.showPaneDetails = true
            try store.update(entry)
        }
        let load = Task { await model.loadDetails() }
        await fixture.provider.started(); await fixture.provider.finish(); await load.value
        #expect(model.presentation.details != nil)
        #expect(dialogSizes(model) == before)
        model.cancel()
    }

    private func dialogSizes(_ model: RequesterHeaderModel) -> [CGSize] {
        let authorizer = FakeBiometricAuthorizer(outcome: .success(()))
        let ssh = SSHAuthRequest(appName: "ssh", appBundleURL: nil, headerModel: model, keyName: "Fixture key",
            triggerCommand: "git fetch", showCommand: true, host: "fixture.example", keychainService: authorizer, callbacks: .noop,
            onResult: { _, _ in })
        let run = RunAuthRequest(appName: "ssh", appBundleURL: nil, headerModel: model, profileName: "Fixture",
            command: "git fetch", scopeOptions: RunAuthWindowController.authorizationScopes(from: ["git", "fetch"]),
            keychainService: authorizer, callbacks: .noop,
            onResult: { _, _, _ in })
        let proposed = CGSize(width: 380, height: 10_000)
        return [NSHostingController(rootView: SSHAuthDialogView(request: ssh)).sizeThatFits(in: proposed),
                NSHostingController(rootView: RunAuthDialogView(request: run)).sizeThatFits(in: proposed)]
    }

    @Test func longDetailsCannotGrowEitherInitiallySizedDialog() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let long = String(repeating: "Synthetic ", count: 26)
        let gate = GatedHeaderDetailsProvider(result: .init(workspaceLabel: long, tabLabel: long,
            paneTitle: long, workingDirectory: "~/" + long))
        let model = RequesterHeaderModel(clientInfo: fixture.client, snapshot: fixture.client.requesterSnapshot,
            store: fixture.store, detailsProvider: TestHeaderDetailsProvider(gate: gate))
        let before = dialogSizes(model)
        #expect(before.allSatisfy { $0.height < 600 })
        let load = Task { await model.loadDetails() }
        await gate.started(); await gate.finish(); await load.value
        #expect(model.presentation.details?.paneTitle == long)
        #expect(dialogSizes(model) == before)
        model.cancel()
    }

    @Test func nilDetailsFallbackCompletesWithoutRetry() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let gate = GatedHeaderDetailsProvider(result: nil)
        let model = RequesterHeaderModel(clientInfo: fixture.client, snapshot: fixture.client.requesterSnapshot,
            store: fixture.store, detailsProvider: TestHeaderDetailsProvider(gate: gate))
        let load = Task { await model.loadDetails() }
        await gate.started(); await gate.finish(); await load.value
        #expect(model.presentation.name == "Herdr")
        #expect(model.presentation.details == nil)
        await model.loadDetails()
        #expect(await gate.calls == 1)
        model.cancel()
    }

    @Test func ancestryDiscoveryUsesInstallationPathBeforeResolving() throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        fixture.defaults.removeObject(forKey: DefaultsKey.terminalHosts)
        let store = TerminalHostStore(defaults: fixture.defaults, discovery: TerminalHostDiscovery(candidates: { [] }))
        #expect(store.entries.isEmpty)
        let model = RequesterHeaderModel(clientInfo: fixture.client, snapshot: fixture.client.requesterSnapshot,
            store: store, detailsProvider: fixture.detailsProvider)
        #expect(store.entries.first?.executablePath == fixture.executable.path)
        #expect(model.presentation.name == "Herdr")
        model.cancel()
    }

    @Test func fallbackDoesNotLookup() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = RequesterHeaderModel(clientInfo: .unknown, snapshot: nil, store: fixture.store, detailsProvider: fixture.detailsProvider)
        await model.loadDetails()
        #expect(model.presentation.name == "Unknown application")
        #expect(await fixture.provider.calls == 0)
        model.cancel()
    }
}

/// Synthetic request-scoped process and filesystem fixtures; never launches the executable.
@MainActor final class RequesterHeaderFixture {
    static let details = HerdrPaneDetails(workspaceLabel: "Workspace", tabLabel: "Tab", paneTitle: "Synthetic pane", workingDirectory: "~/fixture")
    let suite = UUID().uuidString
    let defaults: UserDefaults
    let directory: URL
    let executable: URL
    let store: TerminalHostStore
    let provider = GatedHeaderDetailsProvider()
    let client: SSHClientInfo

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("herdr")
        try Data("synthetic non-runnable fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let path = executable
        store = TerminalHostStore(defaults: defaults, discovery: TerminalHostDiscovery(candidates: { [path] }))
        let requester = RequesterProcessSnapshot.ProcessNode(pid: 100, parentPID: 101, startTimeMicroseconds: 100, executablePath: "/usr/bin/ssh", canonicalExecutablePath: "/usr/bin/ssh")
        let host = RequesterProcessSnapshot.ProcessNode(pid: 101, parentPID: 1, startTimeMicroseconds: 101, executablePath: path.path, canonicalExecutablePath: path.path)
        client = SSHClientInfo(name: "ssh", bundleIdentifier: nil, bundleURL: nil, command: "ssh fixture.example",
            triggerCommand: "git fetch", showCommand: true, batchMode: false,
            requesterSnapshot: .init(requester: requester, ancestors: [host], routingHints: []))
    }

    func model() -> RequesterHeaderModel {
        RequesterHeaderModel(clientInfo: client, snapshot: client.requesterSnapshot, store: store, detailsProvider: detailsProvider)
    }
    var detailsProvider: TestHeaderDetailsProvider { TestHeaderDetailsProvider(gate: provider) }
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

actor GatedHeaderDetailsProvider {
    private(set) var calls = 0
    private(set) var cancellationObserved = false
    private let result: HerdrPaneDetails?
    init(result: HerdrPaneDetails? = .init(workspaceLabel: "Workspace", tabLabel: "Tab", paneTitle: "Synthetic pane", workingDirectory: "~/fixture")) {
        self.result = result
    }
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<Void, Never>?
    func started() async {
        if calls > 0 { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() { resultWaiter?.resume(); resultWaiter = nil }
    func details(for match: TerminalHostMatch) async -> HerdrPaneDetails? {
        calls += 1
        await withCheckedContinuation { continuation in
            resultWaiter = continuation
            startWaiter?.resume(); startWaiter = nil
        }
        cancellationObserved = Task.isCancelled
        return result
    }
}

nonisolated struct TestHeaderDetailsProvider: HerdrPaneDetailsProviding {
    let gate: GatedHeaderDetailsProvider
    func details(for match: TerminalHostMatch) async -> HerdrPaneDetails? { await gate.details(for: match) }
}
