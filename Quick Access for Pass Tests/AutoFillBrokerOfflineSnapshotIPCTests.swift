import Foundation
import GRDB
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill broker offline snapshot IPC")
@MainActor
struct AutoFillBrokerOfflineSnapshotIPCTests {
    @Test("real offline mutation after resolution or registry completion rejects cached frames", arguments: [AutoFillValueKind.password, .oneTimeCode], ["remove", "purge", "replace", "metadata"])
    func mutationRejectsCachedDelivery(kind: AutoFillValueKind, mutation: String) async throws {
        for atCompletion in [false, true] {
            let offline = try OfflineLifecycleFixture(itemIDs: ["item"])
            let item = try #require(offline.items.first)
            let codec = offline.codec()
            let service = OfflineModeService(repository: offline.repository, codec: codec, cliService: IPCSnapshotViewer(
                totpURI: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
            ))
            try await initializeOfflineFixtureService(service)
            try await service.makeAvailableOffline(item: item, shareId: "share")
            let descriptor = AutoFillCredentialDescriptor(
                id: UUID(), vaultID: "vault", itemID: item.id, shareID: "share", title: "Fixture",
                username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true
            )
            let coordinator = AutoFillBrokerCoordinator(
                descriptorStore: GenericIPCDescriptorStore(descriptor: descriptor),
                secretResolver: OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
                    live: GenericIPCUnavailableLive(), repository: offline.repository, codec: codec, readiness: service
                )), isAppLocked: { false }, showLockedPanel: { _ in false }
            )
            let mutate: @Sendable () async throws -> Void = {
                switch mutation {
                case "remove": try await offline.repository.removeItem(item.id)
                case "purge": try await offline.repository.purge()
                case "replace":
                    let request = try #require(try await offline.repository.beginRequest(itemID: item.id, vaultID: "vault", shareID: "share", kind: .refresh))
                    let replacement = try await codec.prepareSnapshot(from: offlineTestCLIItem(id: item.id, vaultID: "vault", shareID: "share",
                        password: "replacement", totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"), for: request)
                    #expect(try await offline.repository.publish(replacement, for: request, refreshedAt: Date()))
                default: try offline.database.syncItems([])
                }
            }
            let gate = OfflineTestGate()
            let fixture = try BrokerFixture()
            defer { fixture.cleanup() }
            let broker = AutoFillBroker(
                listenPath: fixture.socketPath, registry: fixture.registry, launchGate: fixture.launchGate,
                verifier: { fd in VerifiedAutoFillPeer(fileDescriptor: fd, identifier: AutoFillConstants.extensionBundleIdentifier, teamID: "H23TXL6LPT") },
                requestHandler: { request, transition, intent in
                    let delivery = try await coordinator.resolveDelivery(request: request, appAssociationIntent: intent, transition: transition)
                    if !atCompletion { try await gate.wait() }
                    return delivery
                }, candidateHandler: { _ in [] },
                completionGate: { if atCompletion { try? await gate.wait() } }
            )
            try await broker.start()
            let request = AutoFillBrokerRequest(requestID: UUID(), descriptorID: descriptor.id, valueKind: kind,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
            let admission = Task { try await gate.waitUntilEntered() }
            defer { admission.cancel() }
            let client = Task {
                // A transport/expiry failure before admission must not strand the test
                // waiting for a handler gate that can no longer be reached.
                defer { admission.cancel() }
                return try await BrokerTestSocketIO.requestBytesUntilEOF(at: fixture.socketPath, message: request)
            }
            do {
                try await admission.value
                try await mutate()
                await gate.open()
                let bytes = try await client.value
                // Both gates resume before registry completion's final write.
                // Revocation after completion closes with no failure frame;
                // asserting raw EOF bytes rejects partial credential frames too.
                #expect(bytes.isEmpty, "Final cached denial emitted bytes: \(kind) \(mutation)")
                await broker.stop()
                #expect(await broker.activeConnectionCount() == 0)
            } catch {
                await gate.open()
                client.cancel()
                let clientResult = await client.result
                await broker.stop()
                if case .failure(let clientError) = clientResult { throw clientError }
                throw error
            }
        }
    }

    @Test("verified broker returns manual-only password and TOTP snapshots as value-only responses")
    func manualOnlyCacheFirstSnapshotReturnsOnlyRequestedValues() async throws {
        let offline = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(offline.items.first)
        let totpURI = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999"
        let codec = offline.codec()
        let service = OfflineModeService(repository: offline.repository, codec: codec, cliService: IPCSnapshotViewer(totpURI: totpURI))
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        #expect(try await offline.repository.offlineVaultIds().isEmpty)
        #expect(try await offline.repository.offlineItemSelection(itemId: item.id)?.isManuallySelected == true)

        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: item.id, shareID: "share", title: "Fixture",
            username: "person@example.test", serviceIdentifier: "example.test", hasTOTP: true
        )
        let live = IPCUnavailableLiveRecorder()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: GenericIPCDescriptorStore(descriptor: descriptor),
            secretResolver: OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
                live: live, repository: offline.repository, codec: codec, readiness: service
            )),
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let broker = AutoFillBroker(
            listenPath: fixture.socketPath, registry: fixture.registry, launchGate: fixture.launchGate,
            verifier: { fd in
                VerifiedAutoFillPeer(fileDescriptor: fd, identifier: AutoFillConstants.extensionBundleIdentifier, teamID: "H23TXL6LPT")
            },
            requestHandler: { request, transition, intent in
                try await coordinator.resolveDelivery(request: request, appAssociationIntent: intent, transition: transition)
            },
            candidateHandler: { _ in [] }
        )
        try await broker.start()
        do {
            let passwordRequest = AutoFillBrokerRequest(
                requestID: UUID(), descriptorID: descriptor.id, valueKind: .password,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            )
            let password = try await BrokerTestSocketIO.requestTraced(at: fixture.socketPath, message: passwordRequest, trace: BrokerTestTrace())
            #expect(password == .credential(requestID: passwordRequest.requestID, value: "cached-password"))

            let totpRequest = AutoFillBrokerRequest(
                requestID: UUID(), descriptorID: descriptor.id, valueKind: .oneTimeCode,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            )
            let totp = try await BrokerTestSocketIO.requestTraced(at: fixture.socketPath, message: totpRequest, trace: BrokerTestTrace())
            let expectedTOTP = try TOTPGenerator.code(from: totpURI, at: Date())
            #expect(totp == .credential(requestID: totpRequest.requestID, value: expectedTOTP))
            for response in [password, totp] {
                let data = try AutoFillWire.encodeMessage(response)
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(AutoFillBrokerResponse.validateJSONKeys(Set(object.keys), in: object))
                #expect(object["value"] != nil)
                #expect(object["candidates"] == nil)
                #expect(object["failure"] == nil)
            }
            let itemCallCount = await live.itemCallCount()
            let totpCallCount = await live.totpCallCount()
            // Authorized cached requests launch neither native item nor TOTP work.
            #expect(itemCallCount == 0)
            #expect(totpCallCount == 0)
            await broker.stop()
        } catch {
            await broker.stop()
            throw error
        }
    }

    @Test("authenticated malformed encrypted snapshot reaches generic broker IPC failure without marker leakage")
    func authenticatedMalformedSnapshotIsGenericIPCFailure() async throws {
        let offline = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(offline.items.first)
        let codec = offline.codec()
        let service = OfflineModeService(repository: offline.repository, codec: codec, cliService: OfflineFixtureViewer())
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        #expect(try await offline.repository.offlineVaultIds().isEmpty)
        #expect(try await offline.repository.offlineItemSelection(itemId: "item")?.isManuallySelected == true)

        let key = OfflineSnapshotKey(vaultId: "vault", itemId: "item", schemaVersion: OfflineSnapshotLimits.schemaVersion)
        let snapshot = try #require(try await offline.repository.authorizedSnapshot(for: key))
        let marker = "<<TASK7_GENERIC_IPC_DECODER_MARKER>>"
        let cipher = try OfflineSnapshotCipher(keyData: Data(repeating: 7, count: 32))
        var malformedPlaintext = Data("malformed-\(marker)".utf8)
        let payload = try cipher.seal(malformedPlaintext, for: snapshot.identity)
        var authenticatedPlaintext = try cipher.open(payload, for: snapshot.identity)
        #expect(authenticatedPlaintext == malformedPlaintext)
        authenticatedPlaintext.resetBytes(in: 0..<authenticatedPlaintext.count)
        malformedPlaintext.resetBytes(in: 0..<malformedPlaintext.count)
        try await offline.database.writer.write { db in
            try db.execute(
                sql: "UPDATE offlineSnapshots SET encryptedPayload = ? WHERE vaultId = ? AND itemId = ?",
                arguments: [payload, "vault", "item"]
            )
        }

        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "Test",
            username: "user@example.com", serviceIdentifier: "example.test", hasTOTP: false
        )
        let accessibility = GenericIPCAccessibility()
        let decodingCodec = GenericIPCDecodeTrace(codec: codec)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: GenericIPCDescriptorStore(descriptor: descriptor),
            secretResolver: OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
                live: GenericIPCUnavailableLive(), repository: offline.repository, codec: decodingCodec, readiness: service
            )),
            isAppLocked: { false }, showLockedPanel: { _ in false }, accessibility: accessibility
        )
        let fixture = try BrokerFixture()
        defer { fixture.cleanup() }
        let broker = AutoFillBroker(
            listenPath: fixture.socketPath, registry: fixture.registry, launchGate: fixture.launchGate,
            verifier: { fd in
                VerifiedAutoFillPeer(fileDescriptor: fd, identifier: AutoFillConstants.extensionBundleIdentifier, teamID: "H23TXL6LPT")
            },
            requestHandler: { request, transition, intent in
                try await coordinator.resolveDelivery(request: request, appAssociationIntent: intent, transition: transition)
            },
            candidateHandler: { _ in [] }
        )
        try await broker.start()
        do {
            let trace = BrokerTestTrace()
            let request = AutoFillBrokerRequest(
                requestID: UUID(), descriptorID: descriptor.id, valueKind: .password,
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 4_000_000_000
            )
            let response = try await BrokerTestSocketIO.requestTraced(at: fixture.socketPath, message: request, trace: trace)
            #expect(response == .failure(requestID: request.requestID, failure: .resolutionFailed))
            #expect(await decodingCodec.outcome() == .corruptSnapshot)
            // The resolver saw the authenticated but malformed payload through
            // the production decoder and discarded that selected snapshot.
            #expect(try await offline.repository.authorizedSnapshot(for: key) == nil)
            let encoded = try AutoFillWire.encodeMessage(response)
            #expect(String(data: encoded, encoding: .utf8)?.contains(marker) == false)
            #expect(accessibility.events == [.cliFailure])
            #expect(AutoFillAccessibilityEvent.cliFailure.announcement.contains(marker) == false)
            await broker.stop()
        } catch {
            await broker.stop()
            throw error
        }
    }
}

private actor GenericIPCDecodeTrace: OfflineSnapshotCoding {
    enum Outcome: Equatable, Sendable {
        case notAttempted
        case corruptSnapshot
        case otherFailure
    }

    private let codec: any OfflineSnapshotCoding
    private var decodeOutcome: Outcome = .notAttempted

    init(codec: any OfflineSnapshotCoding) { self.codec = codec }

    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        do {
            return try await codec.decodeSnapshot(snapshot)
        } catch let error as OfflineSnapshotCodec.Error {
            decodeOutcome = error == .corruptSnapshot ? .corruptSnapshot : .otherFailure
            throw error
        } catch {
            decodeOutcome = .otherFailure
            throw error
        }
    }

    func outcome() -> Outcome { decodeOutcome }
}

private actor GenericIPCDescriptorStore: AutoFillDescriptorStoring {
    let stored: AutoFillCredentialDescriptor
    init(descriptor: AutoFillCredentialDescriptor) { stored = descriptor }
    func descriptor(id: UUID) -> AutoFillCredentialDescriptor? { id == stored.id ? stored : nil }
}

private actor IPCUnavailableLiveRecorder: OfflineSecretResolvingLive {
    private(set) var itemCalls = 0
    private(set) var totpCalls = 0

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        itemCalls += 1
        throw CLIError.notLoggedIn
    }

    func getTotp(itemId: String, shareId: String) async throws -> String {
        totpCalls += 1
        throw CLIError.notLoggedIn
    }

    func itemCallCount() -> Int { itemCalls }
    func totpCallCount() -> Int { totpCalls }

    func viewItem(itemId: String, shareId: String, timeout: TimeInterval) async throws -> CLIItem {
        try await viewItem(itemId: itemId, shareId: shareId)
    }

    func getTotp(itemId: String, shareId: String, timeout: TimeInterval) async throws -> String {
        try await getTotp(itemId: itemId, shareId: shareId)
    }
}

private struct IPCSnapshotViewer: OfflineItemViewing {
    let totpURI: String

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId,
            password: "cached-password", username: "person@example.test", totp: totpURI
        )
    }
}

private struct GenericIPCUnavailableLive: OfflineSecretResolvingLive {
    func viewItem(itemId _: String, shareId _: String) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId _: String, shareId _: String) async throws -> String { throw CLIError.notLoggedIn }
    func viewItem(itemId _: String, shareId _: String, timeout _: TimeInterval) async throws -> CLIItem { throw CLIError.notLoggedIn }
    func getTotp(itemId _: String, shareId _: String, timeout _: TimeInterval) async throws -> String { throw CLIError.notLoggedIn }
}

@MainActor
private final class GenericIPCAccessibility: AutoFillAccessibilityPresenting {
    private(set) var events: [AutoFillAccessibilityEvent] = []
    func announce(_ event: AutoFillAccessibilityEvent) { events.append(event) }
    func recoverFocusAfterAuthenticationFailure() {}
}
