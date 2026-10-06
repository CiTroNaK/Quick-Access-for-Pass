import Foundation
import GRDB
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill accessibility behavior", .serialized)
@MainActor
struct AutoFillAccessibilityTests {
    @Test("locked requests announce unlock before resolving")
    func unlockRequiredAnnouncement() async throws {
        let accessibility = RecordingAutoFillAccessibilityAdapter()
        let locked = OSAllocatedUnfairLock(initialState: true)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: AccessibilityDescriptorStore(descriptor: descriptor),
            secretResolver: AccessibilitySecretResolver(body: { _, _ in "fake-value" }),
            isAppLocked: { locked.withLock { $0 } },
            showLockedPanel: { _ in
                locked.withLock { $0 = false }
                return true
            },
            accessibility: accessibility
        )

        _ = try await coordinator.resolve(request: makeRequest(lifetime: ordinaryPathLifetime))

        #expect(accessibility.events == [.unlockRequired])
        #expect(accessibility.focusRecoveryCount == 0)
    }

    @Test("a request deadline announces a non-secret timeout")
    func timeoutAnnouncement() async {
        let accessibility = RecordingAutoFillAccessibilityAdapter()
        let coordinator = makeCoordinator(
            accessibility: accessibility,
            isLocked: true,
            unlock: { _ in
                try? await Task.sleep(for: .seconds(1))
                return true
            },
            resolve: { _, _ in "must-not-resolve" }
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.deadlineExpired) {
            try await coordinator.resolve(request: makeRequest(lifetime: 0.2))
        }

        #expect(accessibility.events == [.unlockRequired, .requestTimedOut])
    }

    @Test("Pass CLI failures announce a fixed message without leaking error content")
    func cliFailureAnnouncement() async {
        struct SecretBearingError: Error {
            let value: String
        }

        let accessibility = RecordingAutoFillAccessibilityAdapter()
        let coordinator = makeCoordinator(
            accessibility: accessibility,
            isLocked: false,
            unlock: { _ in true },
            resolve: { _, _ in throw SecretBearingError(value: "never-announce-this-value") }
        )

        await #expect(throws: (any Error).self) {
            try await coordinator.resolve(request: makeRequest())
        }

        #expect(accessibility.events == [.cliFailure])
        #expect(AutoFillAccessibilityEvent.cliFailure.announcement.contains("never-announce-this-value") == false)
    }

    @Test("authenticated decoder marker reaches only fixed AutoFill accessibility presentation")
    func encryptedDecoderMarkerNeverReachesAnnouncement() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let codec = fixture.codec()
        let service = OfflineModeService(repository: fixture.repository, codec: codec, cliService: OfflineFixtureViewer())
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let snapshot = try #require(try await fixture.repository.authorizedSnapshot(for: key))
        let marker = "<<TASK7_DECODER_ACCESSIBILITY_MARKER>>"
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        let payload = try cipher.seal(Data("malformed-\(marker)".utf8), for: snapshot.identity)
        try await fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE offlineSnapshots SET encryptedPayload = ? WHERE vaultId = ? AND itemId = ?",
                arguments: [payload, "vault", "item"]
            )
        }
        let accessibility = RecordingAutoFillAccessibilityAdapter()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: AccessibilityDescriptorStore(descriptor: descriptor),
            secretResolver: OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
                live: AccessibilityOfflineLive(), repository: fixture.repository, codec: codec, readiness: service
            )),
            isAppLocked: { false }, showLockedPanel: { _ in false }, accessibility: accessibility
        )

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.resolve(request: makeRequest(lifetime: ordinaryPathLifetime))
        }
        #expect(accessibility.events == [.cliFailure])
        #expect(AutoFillAccessibilityEvent.cliFailure.announcement.contains(marker) == false)
    }

    @Test("failed authentication asks owned unlock UI to recover accessibility focus")
    func authenticationFailureRecoversFocus() async {
        let accessibility = RecordingAutoFillAccessibilityAdapter()
        let coordinator = makeCoordinator(
            accessibility: accessibility,
            isLocked: true,
            unlock: { _ in false },
            resolve: { _, _ in "must-not-resolve" }
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.unlockFailed) {
            try await coordinator.resolve(request: makeRequest())
        }

        #expect(accessibility.events == [.unlockRequired])
        #expect(accessibility.focusRecoveryCount == 1)
    }

    @Test("production announcements contain no request identifiers or credential values")
    func announcementsAreFixedAndNonSecret() {
        let nonce = UUID().uuidString
        let value = "fake-password-value"

        for event in AutoFillAccessibilityEvent.allCases {
            #expect(event.announcement.contains(nonce) == false)
            #expect(event.announcement.contains(value) == false)
        }
    }

    @Test("app association settings preserve raw IDs and recover VoiceOver focus")
    func appAssociationSettingsAccessibilitySource() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access for Pass/Views/Settings/AutoFillAppAssociationsSettingsView.swift"
            ),
            encoding: .utf8
        )

        for requiredSnippet in [
            "Text(association.service.identifier)",
            ".confirmationDialog(",
            "Forget this app association?",
            ".accessibilityLabel(\"Forget association for \\(association.service.identifier)\")",
            "@AccessibilityFocusState private var accessibilityFocusedServiceIdentifier: String?",
            ".accessibilityFocused($accessibilityFocusedServiceIdentifier, equals: association.service.identifier)",
            "accessibilityFocusedServiceIdentifier = model.associations.first?.service.identifier",
            "AccessibilityNotification.Announcement(message).post()"
        ] {
            #expect(source.contains(requiredSnippet), "Missing app association accessibility behavior: \(requiredSnippet)")
        }
    }

    @Test("candidate picker exposes visible states and accessible controls")
    func pickerAccessibilitySource() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/AutoFillCandidatePickerView.swift"
            ),
            encoding: .utf8
        )

        for requiredSnippet in [
            "Loading credentials…",
            "No matching credentials",
            "Unable to load credentials",
            "Button {",
            "Cancel",
            ".accessibilityAddTraits(isSelected ? .isSelected : [])",
            ".accessibilityHidden(true)",
            "AccessibilityNotification.Announcement",
            "ScrollViewReader",
            ".frame(\n                height: candidateListViewportHeight,",
            ".onKeyPress(.upArrow",
            ".onKeyPress(.downArrow",
            ".onKeyPress(.return",
            ".onKeyPress(.escape",
            "Exact site match",
            ".accessibilityReduceMotion"
        ] {
            #expect(source.contains(requiredSnippet), "Missing picker accessibility behavior: \(requiredSnippet)")
        }
    }

    @Test("global search tier-zero candidates do not present as exact site matches")
    func globalSearchTierZeroCandidatesDoNotPresentAsExactSiteMatches() {
        let candidate = AutoFillCandidate(
            descriptorID: UUID(),
            title: "Example credential",
            username: "person@example.com",
            kind: .password,
            matchTier: 0
        )

        #expect(
            AutoFillCandidatePickerPresentation.showsExactSiteMatch(
                for: candidate,
                in: .searchResults([candidate])
            ) == false
        )
        #expect(
            AutoFillCandidatePickerPresentation.accessibilityLabel(
                for: candidate,
                in: .searchResults([candidate])
            ).contains("Exact site match") == false
        )
        #expect(
            AutoFillCandidatePickerPresentation.showsExactSiteMatch(
                for: candidate,
                in: .siteResults([candidate])
            )
        )
        #expect(
            AutoFillCandidatePickerPresentation.accessibilityLabel(
                for: candidate,
                in: .siteResults([candidate])
            ).contains("Exact site match")
        )
    }

    @Test("candidate picker puts search first and keeps exact-site indication inline")
    func pickerSearchOrderingAndRowDensitySource() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/AutoFillCandidatePickerView.swift"
            ),
            encoding: .utf8
        )
        _ = try #require(source.range(of: "AutoFillPickerSearchField("))
        let searchControls = try #require(source.range(of: "            topControls(searchQuery:"))
        let content = try #require(source.range(of: "            content\n"))

        #expect(searchControls.lowerBound < content.lowerBound)
        #expect(source.contains("HStack(spacing: 4) {"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeCoordinator(
        accessibility: RecordingAutoFillAccessibilityAdapter,
        isLocked: Bool,
        unlock: @escaping @MainActor @Sendable (TimeInterval) async -> Bool,
        resolve: @escaping @Sendable (AutoFillCredentialDescriptor, AutoFillValueKind) async throws -> String
    ) -> AutoFillBrokerCoordinator {
        AutoFillBrokerCoordinator(
            descriptorStore: AccessibilityDescriptorStore(descriptor: descriptor),
            secretResolver: AccessibilitySecretResolver(body: resolve),
            isAppLocked: { isLocked },
            showLockedPanel: unlock,
            accessibility: accessibility
        )
    }

    /// This ordinary-path assertion does not exercise expiry; the dedicated
    /// timeout test below retains its short fixture lifetime.
    private let ordinaryPathLifetime: TimeInterval = 30

    private func makeRequest(lifetime: TimeInterval = 1) -> AutoFillRegisteredRequest {
        AutoFillRegisteredRequest(
            requestID: UUID(),
            descriptorID: descriptor.id,
            kind: .password,
            deadline: DispatchTime.now().uptimeNanoseconds + UInt64(lifetime * 1_000_000_000)
        )
    }

    private var descriptor: AutoFillCredentialDescriptor {
        AutoFillCredentialDescriptor(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            vaultID: "vault",
            itemID: "item",
            shareID: "share",
            title: "Example",
            username: "person@example.com",
            serviceIdentifier: "example.com",
            hasTOTP: true
        )
    }
}

@MainActor
private final class RecordingAutoFillAccessibilityAdapter: AutoFillAccessibilityPresenting {
    private(set) var events: [AutoFillAccessibilityEvent] = []
    private(set) var focusRecoveryCount = 0

    func announce(_ event: AutoFillAccessibilityEvent) {
        events.append(event)
    }

    func recoverFocusAfterAuthenticationFailure() {
        focusRecoveryCount += 1
    }
}

private struct AccessibilityDescriptorStore: AutoFillDescriptorStoring {
    let descriptor: AutoFillCredentialDescriptor

    func descriptor(id: UUID) async throws -> AutoFillCredentialDescriptor? {
        descriptor.id == id ? descriptor : nil
    }
}

private struct AccessibilityOfflineLive: OfflineSecretResolvingLive {
    func viewItem(itemId: String, shareId: String) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String) async throws -> String { throw CLIError.notLoggedIn }
    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String { throw CLIError.notLoggedIn }
}

private struct AccessibilitySecretResolver: AutoFillSecretResolving {
    let body: @Sendable (AutoFillCredentialDescriptor, AutoFillValueKind) async throws -> String

    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind,
        context: SecretResolutionContext
    ) async throws -> String {
        try await body(descriptor, kind)
    }
}
