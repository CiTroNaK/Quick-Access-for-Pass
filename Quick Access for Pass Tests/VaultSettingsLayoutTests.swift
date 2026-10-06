import AppKit
import GRDB
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("Vault settings layout", .serialized)
@MainActor
struct VaultSettingsLayoutTests {
    @Test("Offline consent descriptions remain fully rendered at Settings width")
    func offlineDescriptionsWrap() throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: [])
        let coordinator = OfflineModeCoordinator(
            service: fixture.service(),
            observation: OfflineCatalogObservation(database: fixture.database),
            shareIDForVault: { _ in "share" }
        )
        let actual = try render(OfflineSettingsTab()
            .environment(\.offlineModeCoordinator, coordinator), size: NSSize(width: 480, height: 260))
        let paragraphs = [
            "Selecting a vault stores encrypted offline copies of all its items on this Mac. New items added to selected vaults will also become available offline after syncing.",
            "Items removed individually stay excluded until selected again. Turning off a vault keeps individually selected items."
        ]
        for paragraph in paragraphs {
            let reference = NSHostingView(rootView: Text(paragraph)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 440, alignment: .leading))
            let expected = try render(reference.rootView, size: reference.fittingSize)
            #expect(expected.height >= 20)
            let referenceRendered = expected.containsText(from: expected)
            let paragraphRendered = actual.containsText(from: expected)
            #expect(referenceRendered, "Reference must contain rendered glyphs")
            #expect(paragraphRendered, "Full paragraph must be rendered, not ellipsized")
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
        let referenceRendered = expected.containsText(from: expected)
        let identifierRendered = actual.containsText(from: expected)
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
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

    private func render<Content: View>(_ content: Content, size: NSSize) throws -> RenderedFixture {
        let hosting = NSHostingView(rootView: content
            .environment(\.colorScheme, .light)
            .background(Color.white))
        let window = fixtureWindow(hosting, size: size)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        return try capture(hosting, size: size)
    }

    private func capture(_ hosting: NSView, size: NSSize) throws -> RenderedFixture {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        return try RenderedFixture(image: image, size: size)
    }
}

/// Pixel comparisons operate on isolated non-secret fixtures, never the user's screen.
private struct RenderedFixture {
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

    func containsText(from reference: RenderedFixture) -> Bool {
        let ink = (0..<(reference.width * reference.height)).filter {
            reference.pixels[$0 * 4] < 210 && reference.pixels[$0 * 4 + 3] > 200
        }
        guard ink.count > 50, reference.width <= width, reference.height <= height else { return false }
        // Require the complete multiline glyph pattern. Allow antialiasing differences
        // from fractional SwiftUI origins, not missing/truncated lines.
        for y in 0...(height - reference.height) {
            for x in 0...(width - reference.width) {
                var matched = 0
                for index in ink {
                    let row = index / reference.width
                    let column = index % reference.width
                    let offset = ((y + row) * width + x + column) * 4
                    if pixels[offset] < 225 { matched += 1 }
                }
                if Double(matched) / Double(ink.count) > 0.90 { return true }
            }
        }
        return false
    }
}
