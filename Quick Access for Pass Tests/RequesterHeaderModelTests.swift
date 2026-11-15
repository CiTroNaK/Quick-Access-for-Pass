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
    func dialogFitsVisibleContextAfterLateEnableOrConfigurationChange(change: String) async throws {
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
                                        store: store, detailsProvider: fixture.detailsProvider,
            coreDetailsProvider: fixture.coreDetailsProvider)
        let before = dialogSizes(model)
        #expect(before.allSatisfy { $0.height > 0 && $0.height < 600 })
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
        let after = dialogSizes(model)
        #expect(after.count == 2)
        #expect(zip(after, before).allSatisfy { $0.height > $1.height })
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
            store: fixture.store, detailsProvider: TestHeaderDetailsProvider(gate: gate),
            coreDetailsProvider: fixture.coreDetailsProvider)
        let before = dialogSizes(model)
        #expect(before.allSatisfy { $0.height > 0 && $0.height < 600 })
        let load = Task { await model.loadDetails() }
        await gate.started(); await gate.finish(); await load.value
        #expect(model.presentation.details?.paneTitle == long)
        let after = dialogSizes(model)
        #expect(zip(after, before).allSatisfy { $0.height >= $1.height })
        #expect(after.allSatisfy { $0.height < 600 })
        model.cancel()
    }

    @Test func nilDetailsFallbackCompletesWithoutRetry() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let gate = GatedHeaderDetailsProvider(result: nil)
        let model = RequesterHeaderModel(clientInfo: fixture.client, snapshot: fixture.client.requesterSnapshot,
            store: fixture.store, detailsProvider: TestHeaderDetailsProvider(gate: gate),
            coreDetailsProvider: fixture.coreDetailsProvider)
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
            store: store, detailsProvider: fixture.detailsProvider,
            coreDetailsProvider: fixture.coreDetailsProvider)
        #expect(store.entries.first?.executablePath == fixture.executable.path)
        #expect(model.presentation.name == "Herdr")
        model.cancel()
    }

    @Test func fallbackDoesNotLookup() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = RequesterHeaderModel(clientInfo: .unknown, snapshot: nil, store: fixture.store, detailsProvider: fixture.detailsProvider,
            coreDetailsProvider: fixture.coreDetailsProvider)
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
        RequesterHeaderModel(clientInfo: client, snapshot: client.requesterSnapshot, store: store, detailsProvider: detailsProvider,
                             coreDetailsProvider: coreDetailsProvider)
    }
    var detailsProvider: TestHeaderDetailsProvider { TestHeaderDetailsProvider(gate: provider) }
    let coreProvider = GatedCoreLookupProvider()
    var coreDetailsProvider: TestCoreLookupProvider { TestCoreLookupProvider(gate: coreProvider) }
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

actor GatedCoreLookupProvider {
    private(set) var calls = 0
    private(set) var cancellationObserved = false
    var result: HerdrCoreLookup?
    private(set) var lastIncludeDetails: Bool?
    init(result: HerdrCoreLookup? = nil) { self.result = result }
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<Void, Never>?
    func setResult(_ result: HerdrCoreLookup?) { self.result = result }
    func started() async {
        if calls > 0 { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() { resultWaiter?.resume(); resultWaiter = nil }
    func lookup(_ match: HerdrCoreTerminalMatch, includeDetails: Bool) async -> HerdrCoreLookup? {
        calls += 1
        lastIncludeDetails = includeDetails
        await withCheckedContinuation { continuation in
            resultWaiter = continuation
            startWaiter?.resume(); startWaiter = nil
        }
        cancellationObserved = Task.isCancelled
        return result
    }
}

nonisolated struct TestCoreLookupProvider: HerdrCoreTerminalDetailsProviding {
    let gate: GatedCoreLookupProvider
    func lookup(_ match: HerdrCoreTerminalMatch, includeDetails: Bool) async -> HerdrCoreLookup? {
        await gate.lookup(match, includeDetails: includeDetails)
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct RequesterHeaderModelCoreTests {
    static let details = HerdrPaneDetails(workspaceLabel: "Work / Tab", tabLabel: nil, paneTitle: "review", workingDirectory: "~/p")
    static let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    private func coreClient() -> SSHClientInfo {
        let bundle = "/fixture/Herdr Core.app"
        func node(_ pid: Int32, _ path: String, parent: Int32) -> RequesterProcessSnapshot.ProcessNode {
            .init(pid: pid, parentPID: parent, startTimeMicroseconds: UInt64(pid), executablePath: path, canonicalExecutablePath: path)
        }
        let nodes = [node(200, "/usr/bin/ssh", parent: 201), node(201, "/opt/claude", parent: 202),
                     node(202, "/bin/zsh", parent: 203), node(203, bundle + "/Contents/MacOS/herdr-core", parent: 1)]
        let hint = HerdrCoreRoutingHint(terminalID: "t5", socketPath: "/fixture/core.sock", originatingPID: 201,
                                        originatingStartTimeMicroseconds: 201)
        return SSHClientInfo(name: "Herdr Core", bundleIdentifier: "dev.herdr.core", bundleURL: URL(fileURLWithPath: bundle),
            command: "ssh fixture.example", triggerCommand: "git fetch", showCommand: true, batchMode: false,
            requesterSnapshot: .init(requester: nodes[0], ancestors: Array(nodes.dropFirst()), routingHints: [],
                                     coreRoutingHints: [hint]))
    }

    private func model(_ fixture: RequesterHeaderFixture, settings: HerdrCoreSettings? = nil) -> RequesterHeaderModel {
        let client = coreClient()
        return RequesterHeaderModel(clientInfo: client, snapshot: client.requesterSnapshot, store: fixture.store,
                                    detailsProvider: fixture.detailsProvider, coreDetailsProvider: fixture.coreDetailsProvider,
                                    coreSettings: settings)
    }

    private func load(_ model: RequesterHeaderModel, _ fixture: RequesterHeaderFixture, result: HerdrCoreLookup?) async {
        await fixture.coreProvider.setResult(result)
        let load = Task { await model.loadDetails() }
        await fixture.coreProvider.started(); await fixture.coreProvider.finish(); await load.value
    }

    @Test func coreLookupPublishesOnce() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = model(fixture)
        #expect(model.presentation.name == "Herdr Core")
        #expect(model.presentation.iconOverride == nil)
        #expect(model.detailsEligible)
        await load(model, fixture, result: .init(herdrAppURL: Self.app, details: Self.details))
        #expect(model.presentation.iconOverride == .bundle(Self.app))
        #expect(model.overrideIconImage != nil)
        #expect(model.presentation.details == Self.details)
        #expect(model.presentation.name == "Herdr Core")
        await model.loadDetails()
        #expect(await fixture.coreProvider.calls == 1)
        #expect(await fixture.provider.calls == 0)
        model.cancel()
    }

    @Test func coreWithoutHerdrAppUsesTerminalSymbol() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = model(fixture)
        await load(model, fixture, result: .init(herdrAppURL: nil, details: Self.details))
        #expect(model.presentation.iconOverride == .symbol("terminal"))
        #expect(model.overrideIconImage == nil)
        model.cancel()
    }

    @Test func unrecognizedCoreKeepsPresentation() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = model(fixture)
        let before = model.presentation
        await load(model, fixture, result: nil)
        #expect(model.presentation == before)
        model.cancel()
    }

    @Test(arguments: [false, true])
    func coreCancellationIsTerminal(viewTaskCancellation: Bool) async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = model(fixture)
        await fixture.coreProvider.setResult(.init(herdrAppURL: nil, details: Self.details))
        let load = Task { await model.loadDetails() }
        await fixture.coreProvider.started()
        if viewTaskCancellation { load.cancel() } else { model.cancel() }
        await fixture.coreProvider.finish(); await load.value
        #expect(model.presentation.details == nil)
        #expect(model.presentation.iconOverride == nil)
        #expect(await fixture.coreProvider.cancellationObserved)
        model.cancel()
    }

    @Test func storeChangesDoNotAffectCore() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = model(fixture)
        await fixture.coreProvider.setResult(.init(herdrAppURL: nil, details: Self.details))
        let load = Task { await model.loadDetails() }
        await fixture.coreProvider.started()
        var entry = try #require(fixture.store.entries.first)
        entry.displayName = "Renamed"
        try fixture.store.update(entry)
        await fixture.coreProvider.finish(); await load.value
        #expect(model.presentation.details == Self.details)
        #expect(model.presentation.name == "Herdr Core")
        model.cancel()
    }

    @Test func cancelKeepsOverrideIcon() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = model(fixture)
        await load(model, fixture, result: .init(herdrAppURL: nil, details: Self.details))
        model.cancel()
        #expect(model.presentation.details == nil)
        #expect(model.presentation.iconOverride == .symbol("terminal"))
    }

    @Test func disabledCoreSkipsLookup() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let settings = HerdrCoreSettings(defaults: fixture.defaults)
        settings.isEnabled = false
        let model = model(fixture, settings: settings)
        #expect(!model.detailsEligible)
        await model.loadDetails()
        #expect(await fixture.coreProvider.calls == 0)
        #expect(model.presentation.iconOverride == nil)
        model.cancel()
    }

    @Test func enablingBeforeAnyLookupAllowsIt() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let settings = HerdrCoreSettings(defaults: fixture.defaults)
        settings.isEnabled = false
        let model = model(fixture, settings: settings)
        settings.isEnabled = true
        #expect(model.detailsEligible)
        await load(model, fixture, result: .init(herdrAppURL: nil, details: Self.details))
        #expect(model.presentation.details == Self.details)
        model.cancel()
    }

    @Test(arguments: [true, false])
    func detailsSwitchControlsTheQuery(showsDetails: Bool) async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let settings = HerdrCoreSettings(defaults: fixture.defaults)
        settings.showsDetails = showsDetails
        let model = model(fixture, settings: settings)
        await load(model, fixture, result: .init(herdrAppURL: nil, details: nil))
        #expect(await fixture.coreProvider.lastIncludeDetails == showsDetails)
        model.cancel()
    }

    @Test func turningCoreOffClearsPublishedContext() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let settings = HerdrCoreSettings(defaults: fixture.defaults)
        let model = model(fixture, settings: settings)
        await load(model, fixture, result: .init(herdrAppURL: Self.app, details: Self.details))
        settings.isEnabled = false
        #expect(model.presentation.details == nil)
        #expect(model.presentation.iconOverride == nil)
        #expect(model.overrideIconImage == nil)
        #expect(!model.detailsEligible)
        model.cancel()
    }

    @Test func turningDetailsOffKeepsIcon() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let settings = HerdrCoreSettings(defaults: fixture.defaults)
        let model = model(fixture, settings: settings)
        await load(model, fixture, result: .init(herdrAppURL: nil, details: Self.details))
        settings.showsDetails = false
        #expect(model.presentation.details == nil)
        #expect(model.presentation.iconOverride == .symbol("terminal"))
        model.cancel()
    }

    @Test func turningDetailsOffDuringLookupKeepsIcon() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let settings = HerdrCoreSettings(defaults: fixture.defaults)
        let model = model(fixture, settings: settings)
        await fixture.coreProvider.setResult(.init(herdrAppURL: nil, details: Self.details))
        let load = Task { await model.loadDetails() }
        await fixture.coreProvider.started()
        settings.showsDetails = false
        await fixture.coreProvider.finish(); await load.value
        #expect(model.presentation.iconOverride == .symbol("terminal"))
        #expect(model.presentation.details == nil)
        #expect(await !fixture.coreProvider.cancellationObserved)
        model.cancel()
    }

    @Test func turningCoreOffDuringLookupDropsResult() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let settings = HerdrCoreSettings(defaults: fixture.defaults)
        let model = model(fixture, settings: settings)
        await fixture.coreProvider.setResult(.init(herdrAppURL: Self.app, details: Self.details))
        let load = Task { await model.loadDetails() }
        await fixture.coreProvider.started()
        settings.isEnabled = false
        await fixture.coreProvider.finish(); await load.value
        #expect(model.presentation.details == nil)
        #expect(model.presentation.iconOverride == nil)
        #expect(await fixture.coreProvider.cancellationObserved)
        model.cancel()
    }

    @Test func nonCoreClientNeverCallsCoreProvider() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = fixture.model()
        let load = Task { await model.loadDetails() }
        await fixture.provider.started(); await fixture.provider.finish(); await load.value
        #expect(await fixture.coreProvider.calls == 0)
        model.cancel()
    }

    @Test func coreRowsGrowDialogs() async throws {
        let fixture = try RequesterHeaderFixture(); defer { fixture.cleanUp() }
        let model = model(fixture)
        let before = dialogSizes(model)
        await load(model, fixture, result: .init(herdrAppURL: nil, details: Self.details))
        let after = dialogSizes(model)
        #expect(after.count == 2)
        #expect(zip(after, before).allSatisfy { $0.height > $1.height })
        model.cancel()
    }

    private func dialogSizes(_ model: RequesterHeaderModel) -> [CGSize] {
        let authorizer = FakeBiometricAuthorizer(outcome: .success(()))
        let ssh = SSHAuthRequest(appName: "Herdr Core", appBundleURL: nil, headerModel: model, keyName: "Fixture key",
            triggerCommand: "git fetch", showCommand: true, host: "fixture.example", keychainService: authorizer, callbacks: .noop,
            onResult: { _, _ in })
        let run = RunAuthRequest(appName: "Herdr Core", appBundleURL: nil, headerModel: model, profileName: "Fixture",
            command: "git fetch", scopeOptions: RunAuthWindowController.authorizationScopes(from: ["git", "fetch"]),
            keychainService: authorizer, callbacks: .noop, onResult: { _, _, _ in })
        let proposed = CGSize(width: 380, height: 10_000)
        return [NSHostingController(rootView: SSHAuthDialogView(request: ssh)).sizeThatFits(in: proposed),
                NSHostingController(rootView: RunAuthDialogView(request: run)).sizeThatFits(in: proposed)]
    }
}
