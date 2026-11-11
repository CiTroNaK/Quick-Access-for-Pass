import AppKit
import GRDB
import Observation
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("Vault settings layout", .serialized)
@MainActor
struct VaultSettingsLayoutTests {
    @Test("Proxy Settings renders a launcher for remembered-decision management", arguments: ["SSH", "Run"])
    func rememberedDecisionManagementLauncher(proxy: String) async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: [])
        let suiteName = "RememberedDecisionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let content: AnyView
        if proxy == "SSH" {
            content = AnyView(SSHSettingsTab(sshProxyEnabled: .constant(false), sshUpstreamSocketPath: .constant("")))
        } else {
            content = AnyView(RunSettingsTab(runProxyEnabled: .constant(false)))
        }
        let actual = try render(content
            .environment(ProxyHealthStore())
            .environment(\.databaseManager, fixture.database)
            .defaultAppStorage(defaults), size: NSSize(width: 480, height: 620))
        let label = proxy == "SSH" ? "Manage SSH decisions…" : "Manage Run decisions…"
        // Match the Settings content width to bound the glyph matcher's leading-offset
        // search. The expected text and complete-glyph assertion stay unchanged.
        let reference = NSHostingView(rootView: Text(verbatim: label)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 440, alignment: .leading))
        let expected = try render(reference.rootView, size: reference.fittingSize)
        let referenceRendered = await expected.containsText(from: expected)
        let launcherRendered = await actual.containsText(from: expected)
        #expect(referenceRendered, "Reference must contain rendered glyphs")
        #expect(launcherRendered, "Settings must render the management launcher")
    }

    @Test("Offline consent descriptions remain fully rendered at Settings width")
    func offlineDescriptionsWrap() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: [])
        let coordinator = OfflineModeCoordinator(
            service: fixture.service(),
            observation: OfflineCatalogObservation(database: fixture.database),
            shareIDForVault: { _ in "share" }
        )
        let hosting = NSHostingView(rootView: OfflineSettingsTab()
            .environment(\.offlineModeCoordinator, coordinator)
            .environment(\.colorScheme, .light).background(Color.white).frame(width: 480)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        let collapsedSize = hosting.fittingSize
        let window = fixtureWindow(hosting, size: collapsedSize)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        // Native disclosure click, in this offscreen fixture only; do not activate the app.
        let heading = NSHostingView(rootView: Text("Offline vaults and folders").font(.body)).fittingSize.height
        let introduction = NSHostingView(rootView: Text("Choose whole vaults, folders, or individual items to keep offline.")
            .font(.caption).fixedSize(horizontal: false, vertical: true).frame(width: 440)).fittingSize.height
        let label = NSHostingView(rootView: Text("How offline access works").font(.caption)).fittingSize.height
        let fromTop = 20 + heading + 8 + introduction + 8 + label / 2
        let point = NSPoint(x: 27, y: hosting.isFlipped ? fromTop : hosting.bounds.height - fromTop)
        try click(window, at: hosting.convert(point, to: nil))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        hosting.layoutSubtreeIfNeeded()
        let expandedSize = hosting.fittingSize
        #expect(expandedSize.height > collapsedSize.height, "The native disclosure must expand before checking guidance")
        window.setContentSize(expandedSize)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let actual = try capture(hosting, size: expandedSize)
        let paragraphs = [
            "Selecting a vault stores encrypted offline copies of all its items on this Mac. New items added to selected vaults will also become available offline after syncing.",
            "Items removed individually stay excluded until selected again. Turning off a vault keeps individually selected items.",
            "Items and vaults enabled for Offline Mode use cached values when a usable copy is available. Sync is needed to refresh them. Without a usable cached copy, Quick Access uses Pass CLI.",
            "Offline copies are used for copy actions, Large Type, and System AutoFill. SSH Agent and Run proxies do not use offline copies."
        ]
        for paragraph in paragraphs {
            let reference = NSHostingView(rootView: Text(paragraph)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 432, alignment: .leading))
            let expected = try render(reference.rootView, size: reference.fittingSize)
            #expect(expected.height >= 20)
            let referenceRendered = await expected.containsText(from: expected)
            let paragraphRendered = await actual.containsText(from: expected)
            #expect(referenceRendered, "Reference must contain rendered glyphs")
            #expect(paragraphRendered, "Full paragraph must be rendered, not ellipsized: \(paragraph)")
        }
    }

    @Test("SSH vaults render trailing switches and preserve selection storage")
    func sshVaultsUseTrailingSwitches() throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: [])
        let suiteName = "VaultSettingsLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hosting = NSHostingView(rootView: SSHVaultFilterView()
            .environment(\.databaseManager, fixture.database)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, .light)
            .background(Color.white))
        let window = fixtureWindow(hosting, size: NSSize(width: 440, height: 160))
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let rendered = try capture(hosting, size: hosting.bounds.size)
        let trailingControlRendered = rendered.hasTrailingControl
        #expect(trailingControlRendered, "The switch must be rendered on the right, not a leading checkbox")
        try click(window, at: NSPoint(x: 420, y: 80))
        let data = Data((defaults.string(forKey: DefaultsKey.sshVaultFilter) ?? "[]").utf8)
        #expect(try JSONDecoder().decode([String].self, from: data) == ["Vault"])
        try click(window, at: NSPoint(x: 420, y: 80))
        let empty = Data((defaults.string(forKey: DefaultsKey.sshVaultFilter) ?? "[]").utf8)
        #expect(try JSONDecoder().decode([String].self, from: empty).isEmpty)
    }

    @Test("SSH mixed-case vault order matches the Offline projection")
    func sshVaultOrderMatchesOffline() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: [])
        try fixture.database.upsertVaults([
            PassVault(id: "vault", name: "eval", shareId: "share"),
            PassVault(id: "second", name: "Zoo", shareId: "second-share")
        ])
        let offline = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }
        let firstOfflineName = try #require(offline.vaults.first).vaultName
        #expect(firstOfflineName == "eval")
        let suiteName = "VaultSettingsOrderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hosting = NSHostingView(rootView: SSHVaultFilterView()
            .environment(\.databaseManager, fixture.database)
            .defaultAppStorage(defaults))
        let window = fixtureWindow(hosting, size: NSSize(width: 440, height: 220))
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        // The first of two trailing switches in this fixed-size fixture.
        try click(window, at: NSPoint(x: 420, y: 127))
        let data = Data((defaults.string(forKey: DefaultsKey.sshVaultFilter) ?? "[]").utf8)
        let selectedNames = try JSONDecoder().decode([String].self, from: data)
        #expect(selectedNames == [firstOfflineName])
    }

    @Test("Offline Settings stays compact with a large selected vault")
    func offlinePaneWithLargeVault() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: (0..<200).map { "item-\($0)" })
        for item in fixture.items {
            _ = try await fixture.repository.selectItemManually(itemID: item.id, vaultID: "vault", shareID: "share")
        }
        let presentation = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }
        #expect(presentation.itemGroups.flatMap(\.items).count == 200)
        let coordinator = OfflineModeCoordinator(service: fixture.service(),
            observation: OfflineCatalogObservation(database: fixture.database), shareIDForVault: { _ in "share" })
        coordinator.apply(presentation)
        let hosting = NSHostingView(rootView: OfflineSettingsTab()
            .environment(\.offlineModeCoordinator, coordinator).frame(width: 480))
        #expect(hosting.fittingSize.height < 500, "Main Settings must not grow with the number of selected items")
    }

    @Test("The manager viewport stays bounded and browsing performs no secret work")
    func offlineManagerViewport() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: (0..<200).map { "item-\($0)" })
        for item in fixture.items {
            _ = try await fixture.repository.selectItemManually(itemID: item.id, vaultID: "vault", shareID: "share")
        }
        let presentation = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }
        let keys = OfflineFixtureKeys()
        let viewer = OfflineFixtureViewer()
        let service = OfflineModeService(repository: fixture.repository, codec: fixture.codec(keys: keys), cliService: viewer)
        let coordinator = OfflineModeCoordinator(service: service,
            observation: OfflineCatalogObservation(database: fixture.database), shareIDForVault: { _ in "share" })
        coordinator.apply(presentation)
        let hosting = NSHostingView(rootView: OfflineItemsManagerView(coordinator: coordinator))
        #expect(hosting.fittingSize == NSSize(width: 720, height: 480))
        let window = fixtureWindow(hosting, size: hosting.fittingSize)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        #expect(hosting.bounds.size == NSSize(width: 720, height: 480))
        #expect(OfflineItemsManagerView.filteredGroups(presentation.itemGroups, matching: "OFFLINE").flatMap(\.items).count == 200)
        for item in fixture.items {
            #expect(await viewer.callCount(itemID: item.id) == 0)
        }
        #expect(await keys.createCount() == 0)
        #expect(await keys.existingLookupCount() == 0)
    }

    @Test("Metadata search matches titles, vaults, and types without changing order or selection")
    func offlineManagerSearch() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["a", "b"])
        try fixture.database.upsertVaults([PassVault(id: "second", name: "Alpha", shareId: "second-share")])
        let original = fixture.items[1]
        try fixture.database.upsertItems([PassItem(id: original.id, vaultId: "second", title: "Needle",
            itemType: .login, subtitle: "second@example.test", url: nil, hasTOTP: false, state: "Active",
            createTime: original.createTime, modifyTime: original.modifyTime, useCount: 0, lastUsedAt: nil)])
        _ = try await fixture.repository.selectItemManually(itemID: "a", vaultID: "vault", shareID: "share")
        _ = try await fixture.repository.selectItemManually(itemID: "b", vaultID: "second", shareID: "second-share")
        let before = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }
        #expect(OfflineItemsManagerView.filteredGroups(before.itemGroups, matching: " needle ").flatMap(\.items).map(\.id) == ["b"])
        #expect(OfflineItemsManagerView.filteredGroups(before.itemGroups, matching: "ALPHA").flatMap(\.items).map(\.id) == ["b"])
        #expect(OfflineItemsManagerView.filteredGroups(before.itemGroups, matching: " SECOND@EXAMPLE.TEST ").flatMap(\.items).map(\.id) == ["b"])
        #expect(OfflineItemsManagerView.filteredGroups(before.itemGroups, matching: ItemType.login.displayName).flatMap(\.items).map(\.id) == ["b", "a"])
        #expect(OfflineItemsManagerView.filteredGroups(before.itemGroups, matching: "   ") == before.itemGroups)
        #expect(OfflineItemsManagerView.filteredGroups(before.itemGroups, matching: "fake-password").isEmpty)
        let after = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }
        #expect(after == before)
    }

    @Test("The manager renders the cached username or email beneath the item title")
    func offlineManagerShowsAccountIdentifier() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["a"])
        _ = try await fixture.repository.selectItemManually(itemID: "a", vaultID: "vault", shareID: "share")
        let presentation = try await fixture.database.reader.read { db in
            try OfflineCatalogObservation.presentation(in: db)
        }
        let coordinator = OfflineModeCoordinator(service: fixture.service(),
            observation: OfflineCatalogObservation(database: fixture.database), shareIDForVault: { _ in "share" })
        coordinator.apply(presentation)
        let actual = try render(OfflineItemsManagerView(coordinator: coordinator), size: NSSize(width: 720, height: 480))
        let reference = NSHostingView(rootView: Text(verbatim: "person@example.test")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(width: 200, alignment: .leading))
        let expected = try render(reference.rootView, size: reference.fittingSize)
        let referenceRendered = await expected.containsText(from: expected)
        let identifierRendered = await actual.containsText(from: expected)
        #expect(referenceRendered, "Reference must contain rendered glyphs")
        #expect(identifierRendered, "Account identifier must be rendered, not fetched from a secret")
    }

    @Test("The manager remove button commits removal through the existing coordinator", .timeLimit(.minutes(1)))
    func offlineManagerRemoveBinding() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["a"])
        _ = try await fixture.repository.selectItemManually(itemID: "a", vaultID: "vault", shareID: "share")
        let service = fixture.service()
        try await service.initialize()
        let observation = OfflineCatalogObservation(database: fixture.database)
        var snapshots = observation.snapshots().makeAsyncIterator()
        let initial = try #require(try await snapshots.next())
        let coordinator = OfflineModeCoordinator(service: service, observation: observation, shareIDForVault: { _ in "share" })
        coordinator.apply(initial)
        #expect(coordinator.canRemoveItem("a"))
        let hosting = NSHostingView(rootView: OfflineItemsManagerView(coordinator: coordinator))
        let window = fixtureWindow(hosting, size: NSSize(width: 720, height: 480))
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let table = try #require(descendants(of: hosting).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows >= 2)
        let row = table.rect(ofRow: 1)
        let point = table.convert(NSPoint(x: table.bounds.maxX - 18, y: row.midY), to: nil)
        try click(window, at: point)
        let removed = try #require(try await snapshots.next())
        #expect(removed.itemGroups.isEmpty)
        #expect(try await fixture.repository.itemPolicy(itemID: "a", vaultID: "vault")?.isManuallySelected == false)
        await service.stop()
    }

    @Test("The item Retry row refreshes only its failed target", .timeLimit(.minutes(1)))
    func offlineManagerRetryBindingIsItemScoped() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["target", "neighbor"])
        let target = try #require(fixture.items.first { $0.id == "target" })
        let neighbor = try #require(fixture.items.first { $0.id == "neighbor" })
        func rename(_ item: PassItem, title: String) -> PassItem {
            PassItem(id: item.id, vaultId: item.vaultId, title: title, itemType: item.itemType, subtitle: item.subtitle,
                url: item.url, hasTOTP: item.hasTOTP, state: item.state, createTime: item.createTime,
                modifyTime: item.modifyTime, useCount: item.useCount, lastUsedAt: item.lastUsedAt)
        }
        try fixture.database.upsertItems([rename(target, title: "Target"), rename(neighbor, title: "Neighbor")])
        let failure = LayoutRetryFailureControl()
        let viewer = OfflineFixtureViewer(beforeViewItem: { id in try await failure.check(id) })
        let service = fixture.service(viewer: viewer)
        try await initializeOfflineFixtureService(service)
        _ = try await fixture.repository.selectItemManually(itemID: "target", vaultID: "vault", shareID: "share")
        _ = try await fixture.repository.selectItemManually(itemID: "neighbor", vaultID: "vault", shareID: "share")
        try await service.retrySelectedCopies(vaultID: "vault")
        await service.waitUntilIdle()
        #expect(try await fixture.repository.offlineItemSelection(itemId: "target")?.cacheStatus == .unavailable)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "neighbor")?.cacheStatus == .cached)
        let targetBefore = await viewer.callCount(itemID: "target")
        let neighborBefore = await viewer.callCount(itemID: "neighbor")
        await failure.succeed()

        let initial = try await fixture.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
        let coordinator = OfflineModeCoordinator(
            service: service, observation: LayoutSingleObservation(snapshot: initial), shareIDForVault: { _ in "share" }
        )
        await coordinator.startObservation().value
        #expect(coordinator.canMakeNewSelections)
        #expect(coordinator.itemGroups.flatMap(\.items).count == 2)

        let hosting = NSHostingView(rootView: OfflineItemsManagerView(coordinator: coordinator))
        let window = fixtureWindow(hosting, size: NSSize(width: 720, height: 480))
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let table = try #require(descendants(of: hosting).compactMap { $0 as? NSTableView }.first)
        let targetPosition = try #require(coordinator.itemGroups.first?.items.firstIndex { $0.itemId == "target" })
        let row = table.rect(ofRow: targetPosition + 1)
        let retryGate = OfflineTestGate()
        await failure.pauseTarget(on: retryGate)
        let point = table.convert(NSPoint(x: table.bounds.maxX - 64, y: row.midY), to: nil)
        try click(window, at: point)
        try await retryGate.waitUntilEntered()
        await retryGate.open()
        await service.waitUntilIdle()
        #expect(await viewer.callCount(itemID: "target") == targetBefore + 1)
        #expect(await viewer.callCount(itemID: "neighbor") == neighborBefore)
        #expect(try await fixture.repository.offlineItemSelection(itemId: "neighbor")?.cacheStatus == .cached)
        coordinator.stopObservation()
        await service.stop()
    }

    @Test("Only login and identity metadata supplies an account identifier", arguments: [ItemType.login, .identity, .creditCard, .wifi, .note])
    func accountIdentifierScope(itemType: ItemType) {
        func item(subtitle: String) -> PassItem {
            PassItem(id: "a", vaultId: "vault", title: "Example", itemType: itemType, subtitle: subtitle,
                url: nil, hasTOTP: false, state: "Active", createTime: .distantPast, modifyTime: .distantPast,
                useCount: 0, lastUsedAt: nil)
        }
        let metadata = item(subtitle: " account@example.test ")
        let shouldHaveAccount = itemType == .login || itemType == .identity
        #expect(OfflineItemsManagerView.accountIdentifier(for: metadata) == (shouldHaveAccount ? "account@example.test" : nil))
        #expect(OfflineItemsManagerView.accountIdentifier(for: item(subtitle: " \n ")) == nil)
        let row = OfflineItemSettingsRow(itemId: "a", vaultId: "vault", title: metadata.title,
            itemType: itemType, status: .notCached, lastRefreshedAt: nil, hasUsableSnapshot: false, item: metadata)
        let group = OfflineItemSettingsGroup(vaultId: "vault", vaultName: "Vault", items: [row])
        let results = OfflineItemsManagerView.filteredGroups([group], matching: "account@example.test")
        #expect(!results.isEmpty == shouldHaveAccount)
    }

    private func fixtureWindow(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        return window
    }

    private func click(_ window: NSWindow, at point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func render<Content: View>(_ content: Content, size: NSSize, headerHeight: CGFloat? = nil) throws -> RenderedFixture {
        let hosting = NSHostingView(rootView: content
            .environment(\.colorScheme, .light)
            .background(Color.white))
        let window = fixtureWindow(hosting, size: size)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        if let headerHeight { return try captureHeader(hosting, height: headerHeight) }
        return try capture(hosting, size: size)
    }

    /// TEMPORARY CI DIAGNOSTIC.
    private func launcherDiagnostic(fixture: OfflineFolderManagerFixture) throws -> String {
        let hosting = NSHostingView(rootView: OfflineSettingsTab()
            .environment(\.offlineModeCoordinator, fixture.coordinator)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, .light).background(Color.white))
        let window = fixtureWindow(hosting, size: NSSize(width: 560, height: 440))
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        var found: [String] = []
        var visited = 0
        func walk(_ element: Any, depth: Int) {
            guard depth < 40, let node = element as? NSAccessibilityElementProtocol & NSObjectProtocol else { return }
            visited += 1
            let accessible = node as? NSAccessibilityProtocol
            let label = [accessible?.accessibilityLabel(), accessible?.accessibilityTitle()].compactMap { $0 }.joined(separator: "|")
            if label.contains("Manage folders") {
                let enabled = accessible?.isAccessibilityEnabled() ?? false
                found.append("role=\(accessible?.accessibilityRole()?.rawValue ?? "?") label=\(label) frame=\(node.accessibilityFrame()) enabled=\(enabled)")
            }
            for child in (accessible?.accessibilityChildren() ?? []) { walk(child, depth: depth + 1) }
        }
        walk(hosting, depth: 0)
        let buttonClasses = Set(OfflineFolderManagerFixture.descendants(of: hosting).map { String(describing: type(of: $0)) }
            .filter { $0.localizedCaseInsensitiveContains("button") })
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let coordinator = fixture.coordinator
        return "os=\(os) scale=\(window.backingScaleFactor) hasFolders=\(coordinator.hasFolders(in: "vault")) "
            + "availability=\(coordinator.folderPresentationAvailability) visited=\(visited) "
            + "accessibility=[\(found.joined(separator: "; "))] buttonViews=\(buttonClasses.sorted())"
    }

    private func capture(_ hosting: NSView, size: NSSize) throws -> RenderedFixture {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        return try RenderedFixture(image: image, size: size)
    }
}

extension VaultSettingsLayoutTests {
    private func captureHeader(_ hosting: NSView, height: CGFloat) throws -> RenderedFixture {
        // A tinted selected detail row can satisfy an ink-only glyph matcher; exclude rows.
        let rect = NSRect(x: 0, y: hosting.isFlipped ? 0 : hosting.bounds.height - height,
                          width: hosting.bounds.width, height: height)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: rect))
        hosting.cacheDisplay(in: rect, to: bitmap)
        return try RenderedFixture(image: #require(bitmap.cgImage), size: rect.size)
    }

    @Test("Item detail renders a literal folder path without adding actions", arguments: ["en", "cs"])
    func itemDetailFolderHeader(language: String) async throws {
        let fixture = try await OfflineFolderSyncFixture.make(selectParent: false)
        try await fixture.folder.synchronize(parentName: "Účty %{literal}")
        let model = fixture.viewModel
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let item = try #require(model.items.first { $0.id == "item" })
        model.detailItem = item
        model.selectDetailRow(at: 1)
        #expect(model.folderLocation(for: item.id)?.path == "Účty %{literal} / Child")
        let commands = await fixture.runner.arguments()
        let actual = try render(ItemDetailView(item: item, viewModel: model, onBack: {})
            .environment(\.locale, Locale(identifier: language)), size: NSSize(width: 480, height: 400), headerHeight: 64)
        let reference = NSHostingView(rootView: Text(verbatim: "Účty %{literal} / Child")
            .font(.caption2).foregroundStyle(.tertiary).fixedSize())
        let expected = try render(reference.rootView, size: reference.fittingSize)
        let validReference = await expected.containsText(from: expected)
        let folderRendered = await actual.containsText(from: expected)
        #expect(validReference)
        #expect(folderRendered, "The detail header must render the committed literal folder path")
        #expect(model.rows(for: item).map(\.id) == ["named:copyUsername", "named:copyPassword"])
        #expect(model.selectedDetailRowID == "named:copyPassword", "Metadata must not displace the selected secret action")
        #expect(await fixture.runner.arguments() == commands, "Rendering metadata must not invoke Pass CLI")
        await fixture.finish()
    }

    @Test("Item detail omits paths after a probe invalidates the load stamp", arguments: ["checking", "2.4.2", "2.5.1"])
    func itemDetailHidesObsoleteFolderHeader(version: String) async throws {
        let fixture = try await OfflineFolderSyncFixture.make(selectParent: false)
        let model = fixture.viewModel
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let item = try #require(model.items.first { $0.id == "item" })
        #expect(model.folderLocation(for: item.id)?.path == "Parent / Child")
        let probe = fixture.cli.folderFeatureGate.beginProbe()
        if version != "checking" {
            fixture.cli.folderFeatureGate.confirm(capabilities: .init(rawVersionString: version), for: probe)
        }
        let actual = try render(ItemDetailView(item: item, viewModel: model, onBack: {}),
                                size: NSSize(width: 480, height: 400), headerHeight: 64)
        let reference = NSHostingView(rootView: Text(verbatim: "Parent / Child")
            .font(.caption2).foregroundStyle(.tertiary).fixedSize())
        let expected = try render(reference.rootView, size: reference.fittingSize)
        let validReference = await expected.containsText(from: expected)
        let folderRendered = await actual.containsText(from: expected)
        #expect(validReference)
        #expect(!folderRendered, "Neither retained metadata nor a newly supported probe can revive an old load stamp")
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("Item detail omits root and unresolved locations", arguments: ["root-item", "unresolved"])
    func itemDetailOmitsUnknownFolderHeader(itemID: String) async throws {
        let fixture = try await OfflineFolderSyncFixture.make(selectParent: false)
        let model = fixture.viewModel
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let item = model.items.first { $0.id == itemID } ?? offlineTestMetadata(id: itemID, vaultID: "vault")
        let actual = try render(ItemDetailView(item: item, viewModel: model, onBack: {}),
                                size: NSSize(width: 480, height: 400), headerHeight: 64)
        let reference = NSHostingView(rootView: Text(verbatim: "Parent / Child")
            .font(.caption2).foregroundStyle(.tertiary).fixedSize())
        let expected = try render(reference.rootView, size: reference.fittingSize)
        let folderRendered = await actual.containsText(from: expected)
        #expect(!folderRendered, "Another item's folder must never be substituted for an unresolved location")
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("Long detail paths remain a single bounded header line", arguments: [180.0, 480.0])
    func itemDetailLongFolderHeaderStaysBounded(width: Double) async throws {
        let fixture = try await OfflineFolderSyncFixture.make(selectParent: false)
        let model = fixture.viewModel
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let item = try #require(model.items.first { $0.id == "item" })
        let ordinary = NSHostingView(rootView: ItemDetailView(item: item, viewModel: model, onBack: {}).frame(width: width))
            .fittingSize
        try await fixture.folder.synchronize(parentName: String(repeating: "Osobní / %{literal} — účty ", count: 50))
        model.performSearch(query: "Offline")
        await model.folderLocationsTask?.value
        let long = NSHostingView(rootView: ItemDetailView(item: item, viewModel: model, onBack: {}).frame(width: width))
            .fittingSize
        #expect(ordinary.height > 0)
        #expect(long.height == ordinary.height, "Folder names must truncate rather than grow the detail header")
        #expect(abs(long.width - width) < 0.001, "Allow only floating-point layout noise, not horizontal expansion")
        #expect(await fixture.runner.views().isEmpty)
        await fixture.finish()
    }

    @Test("Offline folder launcher appears only for vaults with folders", arguments: [0, 1])
    func offlineFolderLauncherRequiresFolderMetadata(folderCount: Int) async throws {
        let fixture = try await OfflineFolderManagerFixture()
        fixture.present(OfflineFolderManagerFixture.rows(count: folderCount))
        let actual = try render(OfflineSettingsTab()
            .environment(\.offlineModeCoordinator, fixture.coordinator)
            .environment(\.locale, Locale(identifier: "en")), size: NSSize(width: 560, height: 440))
        // Match the same native control: a bordered button title antialiases differently from plain Text,
        // which falls just under the glyph threshold on 1x CI runners.
        let reference = NSHostingView(rootView: Button("Manage folders…") {}.fixedSize())
        let expected = try render(reference.rootView, size: reference.fittingSize)
        let referenceRendered = await expected.containsText(from: expected)
        let launcherRendered = await actual.containsText(from: expected)
        // TEMPORARY CI DIAGNOSTIC: report structural presence and the best glyph score.
        let diagnostic = try launcherDiagnostic(fixture: fixture) + " bestScore=\(await actual.bestTextMatchScore(from: expected))"
        withKnownIssue { Issue.record("LAUNCHER-DIAGNOSTIC folderCount=\(folderCount) rendered=\(launcherRendered) \(diagnostic)") }
        #expect(referenceRendered, "The launcher glyph reference must be valid")
        #expect(launcherRendered == (folderCount > 0), "Only a vault with folder metadata should show Manage folders. \(diagnostic)")
        let vaultReference = NSHostingView(rootView: Text(verbatim: "Synthetic vault").font(.body).fixedSize())
        let vaultGlyphs = try render(vaultReference.rootView, size: vaultReference.fittingSize)
        let vaultRendered = await actual.containsText(from: vaultGlyphs)
        #expect(vaultRendered, "Vaults without folders must remain in whole-vault Offline settings")
        #expect(await fixture.viewCallCount("item") == 0)
        await fixture.service.stop()
    }

    @Test("Folder manager does not offer empty or unknown vault names", arguments: ["vault", "empty", "unknown"])
    func folderManagerOmitsEmptySelectedVaultLabels(initialVaultID: String) async throws {
        let fixture = try await OfflineFolderManagerFixture()
        let names = [("vault", "Folder vault"), ("empty", "Empty vault"), ("unknown", "Unknown vault")]
        let vaults = names.map { id, name in
            OfflineVaultSettingsRow(id: id, vaultName: name, isSelected: false,
                selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
        }
        fixture.present(vaults: vaults, rowsByVaultID: ["vault": OfflineFolderManagerFixture.rows(count: 1), "empty": []])
        let actual = try render(OfflineFoldersManagerView(coordinator: fixture.coordinator, initialVaultID: initialVaultID)
            .environment(\.locale, Locale(identifier: "en")), size: NSSize(width: 720, height: 480))
        for (id, name) in names {
            let reference = NSHostingView(rootView: Text(verbatim: name).font(.body).fixedSize())
            let expected = try render(reference.rootView, size: reference.fittingSize)
            let referenceRendered = await expected.containsText(from: expected)
            let nameRendered = await actual.containsText(from: expected)
            #expect(referenceRendered)
            #expect(nameRendered == (id == "vault" && initialVaultID == "vault"),
                    "Empty and undiscovered vault names must not remain selectable, and selection must not silently retarget")
        }
        #expect(fixture.coordinator.vaults.map(\.id) == ["vault", "empty", "unknown"])
        #expect(await fixture.viewCallCount("item") == 0)
        #expect(try await fixture.folders.repository.offlineItemSelections().isEmpty)
        await fixture.service.stop()
    }

    @Test("Missing folder discovery must not claim the chosen vault is empty")
    func folderManagerUnavailableCatalogDoesNotClaimEmpty() async throws {
        let fixture = try await OfflineFolderManagerFixture()
        let vault = OfflineVaultSettingsRow(id: "vault", vaultName: "Unverified vault", isSelected: false,
            selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
        fixture.coordinator.apply(.init(vaults: [vault], itemGroups: [], selectedVaultIDs: [],
            policyByItemID: [:], availabilityByItemID: [:]))
        #expect(!fixture.coordinator.folderDiscoveryIsCurrent(vaultID: "vault"))
        let actual = try render(OfflineFoldersManagerView(coordinator: fixture.coordinator, initialVaultID: "vault")
            .environment(\.locale, Locale(identifier: "en")), size: NSSize(width: 720, height: 480))
        let reference = NSHostingView(rootView: Text("Unavailable").font(.body).fixedSize())
        let expected = try render(reference.rootView, size: reference.fittingSize)
        let referenceRendered = await expected.containsText(from: expected)
        let unavailableRendered = await actual.containsText(from: expected)
        #expect(referenceRendered)
        #expect(unavailableRendered, "An unverified catalog requires an unavailable placeholder, not a known-empty claim")
        #expect(await fixture.viewCallCount("item") == 0)
        await fixture.service.stop()
    }

    @Test("Losing the last folder keeps the open manager on its chosen identity", .timeLimit(.minutes(1)))
    func folderManagerDoesNotRetargetWhenLastFolderDisappears() async throws {
        let fixture = try await OfflineFolderManagerFixture()
        let vaults = [("vault", "Chosen folder vault"), ("other", "Other folder vault")].map { id, name in
            OfflineVaultSettingsRow(id: id, vaultName: name, isSelected: false,
                selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)
        }
        let chosenRows = OfflineFolderManagerFixture.rows(count: 1)
        let otherRows = [OfflineFolderSettingsRow(vaultID: "other", folderID: "other-folder", folderName: "Other folder",
            location: .init(folderID: "other-folder", ancestorNames: ["Other folder"]), isSelected: false,
            coveringAncestorID: nil, selectedCount: 0, usableCount: 0, lastRefreshedAt: nil)]
        fixture.present(vaults: vaults, rowsByVaultID: ["vault": chosenRows, "other": otherRows])
        let hosting = NSHostingView(rootView: OfflineFoldersManagerView(coordinator: fixture.coordinator, initialVaultID: "vault")
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, .light).background(Color.white))
        let size = NSSize(width: 720, height: 480)
        let window = fixtureWindow(hosting, size: size)
        defer { window.orderOut(nil); window.contentView = nil }
        let chosenReference = NSHostingView(rootView: Text(verbatim: "Chosen folder vault").font(.body).fixedSize())
        let chosenGlyphs = try render(chosenReference.rootView, size: chosenReference.fittingSize)
        let otherReference = NSHostingView(rootView: Text(verbatim: "Other folder vault").font(.body).fixedSize())
        let otherGlyphs = try render(otherReference.rootView, size: otherReference.fittingSize)
        for hasFolders in [true, false, true] {
            fixture.present(vaults: vaults, rowsByVaultID: ["vault": hasFolders ? chosenRows : [], "other": otherRows])
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let actual = try capture(hosting, size: size)
            let chosenRendered = await actual.containsText(from: chosenGlyphs)
            let otherRendered = await actual.containsText(from: otherGlyphs)
            #expect(chosenRendered == hasFolders)
            #expect(!otherRendered, "Catalog updates must never silently select another vault")
            #expect(fixture.coordinator.vaults.map(\.id) == ["vault", "other"])
        }
        #expect(await fixture.viewCallCount("item") == 0)
        #expect(try await fixture.folders.repository.offlineItemSelections().isEmpty)
        await fixture.service.stop()
    }

    @Test("Dismissing the real folder manager sheet does not cancel submitted work", .timeLimit(.minutes(1)))
    func folderManagerNativeDismissal() async throws {
        let fetch = OfflineTestGate()
        let events = AsyncStream<String>.makeStream()
        defer { events.continuation.finish() }
        let presentation = FolderManagerSheetPresentation()
        let fixture = try await OfflineFolderManagerFixture(beforeView: { try await fetch.wait() })
        let hosting = NSHostingView(rootView: FolderManagerSheetFixture(
            coordinator: fixture.coordinator, presentation: presentation, events: events.continuation))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 720, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        var phase = "appearance"
        do {
            window.update()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentation.isPresented = true }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            hosting.layoutSubtreeIfNeeded()
            var iterator = events.stream.makeAsyncIterator()
            let appeared = await iterator.next()
            try #require(appeared == "appeared")
            do {
                let content = try #require(window.attachedSheet?.contentView)
                #expect(content.bounds.size == NSSize(width: 720, height: 480))
            }
            #expect(await fixture.viewCallCount("item") == 0)
            phase = "submitted fetch"
            try await fixture.coordinator.setFolderSelected(true, folderID: "child", vaultID: "vault")
            try await fetch.waitUntilEntered()
            phase = "dismissal"
            // Keep the presenter alive and observe the native sheet's dismissal contract.
            withTransaction(transaction) { presentation.isPresented = false }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            hosting.layoutSubtreeIfNeeded()
            let dismissed = await iterator.next()
            try #require(dismissed == "dismissed")
            #expect(window.attachedSheet == nil)
            await fetch.open()
            phase = "service settlement"
            await fixture.service.waitUntilIdle()
            #expect(try await fixture.folders.snapshot() != nil)
            #expect(await fixture.viewCallCount("item") == 1)
            #expect(await fixture.viewCallCount("other-item") == 0)
        } catch {
            Issue.record("Native sheet lifecycle failed during \(phase)")
            await fetch.open()
            await fixture.service.stop()
            throw error
        }
        await fixture.service.stop()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test("Vault names remain verbatim even when they match interface translation keys",
          arguments: ["en", "cs"], ["offline", "ssh"])
    func localizedVaultListsPreserveNames(language: String, list: String) async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: [])
        try fixture.database.upsertVaults([
            PassVault(id: "vault", name: "Cached", shareId: "share"),
            PassVault(id: "second", name: "Uloženo", shareId: "second-share")
        ])
        let suiteName = "VaultNameLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let content: AnyView
        if list == "offline" {
            let snapshot = try await fixture.database.reader.read { try OfflineCatalogObservation.presentation(in: $0) }
            let coordinator = OfflineModeCoordinator(service: fixture.service(),
                observation: OfflineCatalogObservation(database: fixture.database), shareIDForVault: { _ in "share" })
            coordinator.apply(snapshot)
            content = AnyView(OfflineSettingsTab().environment(\.offlineModeCoordinator, coordinator))
        } else {
            content = AnyView(SSHVaultFilterView().environment(\.databaseManager, fixture.database)
                .defaultAppStorage(defaults))
        }
        let actual = try render(content.environment(\.locale, Locale(identifier: language)),
                                size: NSSize(width: 480, height: 620))
        for name in ["Cached", "Uloženo"] {
            let reference = NSHostingView(rootView: Text(verbatim: name).font(.body)
                .foregroundStyle(.secondary).fixedSize().frame(width: 200, alignment: .leading))
            let expected = try render(reference.rootView, size: reference.fittingSize)
            let nameRendered = await actual.containsText(from: expected)
            #expect(nameRendered, "\(list) must preserve the distinct vault name \(name) in \(language)")
        }
    }
}

@MainActor @Observable
private final class FolderManagerSheetPresentation {
    var isPresented = false
}

@MainActor
private struct FolderManagerSheetFixture: View {
    let coordinator: OfflineModeCoordinator
    @Bindable var presentation: FolderManagerSheetPresentation
    let events: AsyncStream<String>.Continuation

    var body: some View {
        Color.white.frame(width: 720, height: 480)
            .sheet(isPresented: $presentation.isPresented, onDismiss: { events.yield("dismissed") }, content: {
                OfflineFoldersManagerView(coordinator: coordinator, initialVaultID: "vault")
                    .onAppear { events.yield("appeared") }
            })
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
    }
}

private struct LayoutSingleObservation: OfflineCatalogObserving {
    let snapshot: OfflinePresentationSnapshot
    func snapshots() -> AsyncThrowingStream<OfflinePresentationSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
}

private actor LayoutRetryFailureControl {
    private var failsTarget = true
    private var targetGate: OfflineTestGate?
    func succeed() { failsTarget = false }
    func pauseTarget(on gate: OfflineTestGate) { targetGate = gate }
    func check(_ itemID: String) async throws {
        if itemID == "target", failsTarget { throw CLIError.notLoggedIn }
        if itemID == "target", let targetGate { try await targetGate.wait() }
    }
}

/// Pixel comparisons operate on isolated non-secret fixtures, never the user's screen.
private struct RenderedFixture: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(image: CGImage, size: NSSize) throws {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        let drew = buffer.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drew)
        pixels = buffer
    }

    var hasTrailingControl: Bool {
        var ink = 0
        for y in (height / 2 - 14)...(height / 2 + 14) {
            for x in (width - 55)..<width {
                if pixels[(y * width + x) * 4] < 245 { ink += 1 }
            }
        }
        return ink > 150
    }

    @concurrent
    func containsText(from reference: RenderedFixture) async -> Bool {
        matchText(from: reference)
    }

    /// TEMPORARY CI DIAGNOSTIC: the best fraction of reference ink matched at any offset.
    func bestTextMatchScore(from reference: RenderedFixture) async -> Double {
        let ink = (0..<(reference.width * reference.height)).filter {
            reference.pixels[$0 * 4] < 210 && reference.pixels[$0 * 4 + 3] > 200
        }
        guard !ink.isEmpty, reference.width <= width, reference.height <= height else { return 0 }
        var best = 0
        for y in 0...(height - reference.height) {
            for x in 0...(width - reference.width) {
                var matched = 0
                for index in ink {
                    let offset = ((y + index / reference.width) * width + x + index % reference.width) * 4
                    if pixels[offset] < 225 { matched += 1 }
                }
                best = max(best, matched)
            }
        }
        return (Double(best) / Double(ink.count) * 1000).rounded() / 1000
    }

    private func matchText(from reference: RenderedFixture) -> Bool {
        #expect(!Thread.isMainThread, "Pure pixel matching must not block the UI thread")
        let ink = (0..<(reference.width * reference.height)).filter {
            reference.pixels[$0 * 4] < 210 && reference.pixels[$0 * 4 + 3] > 200
        }
        guard ink.count > 50, reference.width <= width, reference.height <= height else { return false }
        // Require the complete multiline glyph pattern. Allow antialiasing differences
        // from fractional SwiftUI origins, not missing/truncated lines.
        for y in 0...(height - reference.height) {
            for x in 0...(width - reference.width) {
                var matched = 0
                for (position, index) in ink.enumerated() {
                    let row = index / reference.width
                    let column = index % reference.width
                    let offset = ((y + row) * width + x + column) * 4
                    if pixels[offset] < 225 { matched += 1 }
                    // Stop only when even matching every remaining pixel cannot satisfy
                    // the existing complete-pattern threshold; acceptance is unchanged.
                    let maximumMatches = matched + ink.count - position - 1
                    if Double(maximumMatches) / Double(ink.count) <= 0.90 { break }
                }
                if Double(matched) / Double(ink.count) > 0.90 { return true }
            }
        }
        return false
    }
}
