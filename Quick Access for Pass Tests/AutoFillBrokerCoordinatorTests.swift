import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill broker coordinator", .serialized)
struct AutoFillBrokerCoordinatorTests {
    @Test("descriptor lookup precedes password resolution and dispatches the opaque descriptor")
    @MainActor
    func descriptorBeforePasswordResolution() async throws {
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let descriptor = makeDescriptor(hasTOTP: true)
        let store = FakeAutoFillDescriptorStore(descriptor: descriptor) {
            events.withLock { $0.append("descriptor") }
        }
        let resolver = FakeAutoFillSecretResolver { received, kind in
            events.withLock { $0.append("resolver") }
            #expect(received == descriptor)
            #expect(kind == .password)
            return "resolved-password"
        }
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: store,
            secretResolver: resolver,
            isAppLocked: { false },
            showLockedPanel: { _ in Issue.record("Unlocked requests must not show the panel"); return false }
        )

        let result = try await coordinator.resolve(
            request: makeRequest(kind: .password, lifetime: ordinaryPathLifetime)
        )

        #expect(result == "resolved-password")
        #expect(events.withLock { $0 } == ["descriptor", "resolver"])
    }

    @Test("locked request waits for unlock with only remaining time, then resolves TOTP")
    @MainActor
    func lockedRequestUsesRemainingDeadline() async throws {
        let descriptor = makeDescriptor(hasTOTP: true)
        let observedTimeout = OSAllocatedUnfairLock<Double?>(initialState: nil)
        let states = OSAllocatedUnfairLock(initialState: [AutoFillRequestState]())
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor),
            secretResolver: FakeAutoFillSecretResolver { _, kind in
                #expect(kind == .oneTimeCode)
                return "123456"
            },
            isAppLocked: { true },
            showLockedPanel: { timeout in
                observedTimeout.withLock { $0 = timeout }
                return true
            }
        )

        let result = try await coordinator.resolve(
            request: makeRequest(kind: .oneTimeCode, lifetime: 1),
            transition: { state in states.withLock { $0.append(state) } }
        )

        #expect(result == "123456")
        #expect(states.withLock { $0 } == [.awaitingUnlock, .resolving])
        let timeout = try #require(observedTimeout.withLock { $0 })
        #expect(timeout > 0 && timeout <= 1)
    }

    @Test("expired deadline never invokes unlock or Pass CLI resolution")
    @MainActor
    func expiredDeadlineStopsBeforeSecretResolution() async {
        let unlockCalls = OSAllocatedUnfairLock(initialState: 0)
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: makeDescriptor()),
            secretResolver: FakeAutoFillSecretResolver { _, _ in
                resolverCalls.withLock { $0 += 1 }
                return "must-not-resolve"
            },
            isAppLocked: { true },
            showLockedPanel: { _ in
                unlockCalls.withLock { $0 += 1 }
                return true
            }
        )
        let expired = AutoFillRegisteredRequest(
            requestID: UUID(),
            descriptorID: makeDescriptor().id,
            kind: .password,
            deadline: DispatchTime.now().uptimeNanoseconds
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.deadlineExpired) {
            try await coordinator.resolve(request: expired)
        }
        #expect(unlockCalls.withLock { $0 } == 0)
        #expect(resolverCalls.withLock { $0 } == 0)
    }

    @Test("deadline while awaiting unlock prevents later Pass CLI resolution")
    @MainActor
    func deadlineWhileLockedStopsResolution() async {
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: makeDescriptor()),
            secretResolver: FakeAutoFillSecretResolver { _, _ in
                resolverCalls.withLock { $0 += 1 }
                return "must-not-resolve"
            },
            isAppLocked: { true },
            showLockedPanel: { timeout in
                try? await Task.sleep(for: .seconds(timeout + 1))
                return true
            }
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.deadlineExpired) {
            try await coordinator.resolve(request: makeRequest(kind: .password, lifetime: 0.03))
        }
        #expect(resolverCalls.withLock { $0 } == 0)
    }

    @Test("cancellation while locked prevents later Pass CLI resolution")
    @MainActor
    func cancellationWhileLockedStopsResolution() async {
        let unlockStarted = OSAllocatedUnfairLock(initialState: false)
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: makeDescriptor()),
            secretResolver: FakeAutoFillSecretResolver { _, _ in
                resolverCalls.withLock { $0 += 1 }
                return "must-not-resolve"
            },
            isAppLocked: { true },
            showLockedPanel: { _ in
                unlockStarted.withLock { $0 = true }
                do { try await Task.sleep(for: .seconds(10)) } catch { return false }
                return true
            }
        )
        let task = Task { @MainActor in
            try await coordinator.resolve(request: makeRequest(kind: .password, lifetime: 5))
        }
        while unlockStarted.withLock({ !$0 }) { await Task.yield() }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(resolverCalls.withLock { $0 } == 0)
    }

    @Test("listing returns bounded candidates without unlocking or resolving a secret")
    @MainActor
    func listingAvoidsSecretResolution() async throws {
        let descriptor = makeDescriptor()
        let expected = [AutoFillCandidate(
            descriptorID: descriptor.id,
            title: descriptor.title,
            username: descriptor.username,
            kind: .password,
            matchTier: 0
        )]
        let unlockCalls = OSAllocatedUnfairLock(initialState: 0)
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let store = FakeAutoFillDescriptorStore(descriptor: descriptor, candidates: expected)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: store,
            secretResolver: FakeAutoFillSecretResolver { _, _ in
                resolverCalls.withLock { $0 += 1 }
                return "must-not-resolve"
            },
            isAppLocked: { true },
            showLockedPanel: { _ in
                unlockCalls.withLock { $0 += 1 }
                return true
            }
        )
        let query = AutoFillCandidateQuery.global(
            requestID: UUID(), search: "Example", kind: .password,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        )

        let candidates = try await coordinator.listCandidates(query: query)

        #expect(candidates == expected)
        #expect(unlockCalls.withLock { $0 } == 0)
        #expect(resolverCalls.withLock { $0 } == 0)
    }

    @Test("resolution without an explicit app intent does not save an association")
    @MainActor
    func resolutionWithoutAppIntentDoesNotSaveAssociation() async throws {
        let descriptor = makeDescriptor()
        let associations = FakeAutoFillAppAssociationStore()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor),
            associationStore: associations,
            secretResolver: FakeAutoFillSecretResolver { _, _ in "resolved" },
            isAppLocked: { false },
            showLockedPanel: { _ in false }
        )

        _ = try await coordinator.resolve(request: makeRequest(kind: .password))

        #expect(await associations.saved.isEmpty)
    }

    @Test("resolution saves only an explicit native-app association after descriptor validation")
    @MainActor
    func resolutionSavesExplicitAppAssociation() async throws {
        let descriptor = makeDescriptor()
        let associations = FakeAutoFillAppAssociationStore()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor),
            associationStore: associations,
            secretResolver: FakeAutoFillSecretResolver { _, _ in "resolved" },
            isAppLocked: { false },
            showLockedPanel: { _ in false }
        )
        let intent = try AutoFillAppAssociationIntent(service: AutoFillServiceIdentifier(
            kind: .app, identifier: "com.example.app", displayName: "Example"
        ))

        let value = try await coordinator.resolve(
            request: makeRequest(kind: .password),
            appAssociationIntent: intent
        )

        #expect(value == "resolved")
        #expect(await associations.saved == [SavedAssociation(service: intent.service, descriptorID: descriptor.id)])
    }

    @Test("resolution does not save an association when the descriptor is missing")
    @MainActor
    func missingDescriptorDoesNotSaveAssociation() async throws {
        let associations = FakeAutoFillAppAssociationStore()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: nil),
            associationStore: associations,
            secretResolver: FakeAutoFillSecretResolver { _, _ in "must-not-resolve" },
            isAppLocked: { false },
            showLockedPanel: { _ in false }
        )
        let intent = try AutoFillAppAssociationIntent(service: AutoFillServiceIdentifier(
            kind: .app, identifier: "com.example.app", displayName: nil
        ))

        await #expect(throws: AutoFillBrokerCoordinator.Error.descriptorNotFound) {
            try await coordinator.resolve(request: makeRequest(kind: .password), appAssociationIntent: intent)
        }
        #expect(await associations.saved.isEmpty)
    }

    @Test("missing descriptor fails without invoking the resolver")
    @MainActor
    func missingDescriptorDoesNotResolve() async {
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: nil),
            secretResolver: FakeAutoFillSecretResolver { _, _ in
                resolverCalls.withLock { $0 += 1 }
                return "must-not-resolve"
            },
            isAppLocked: { false },
            showLockedPanel: { _ in false }
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.descriptorNotFound) {
            try await coordinator.resolve(request: makeRequest(kind: .password))
        }
        #expect(resolverCalls.withLock { $0 } == 0)
    }

    /// Normal-path tests use the production maximum so unrelated MainActor test
    /// scheduling cannot consume their fixture deadline. Dedicated deadline tests
    /// below retain their short lifetimes.
    private let ordinaryPathLifetime: TimeInterval = 30

    private func makeRequest(
        kind: AutoFillValueKind,
        lifetime: TimeInterval = 2
    ) -> AutoFillRegisteredRequest {
        AutoFillRegisteredRequest(
            requestID: UUID(),
            descriptorID: makeDescriptor().id,
            kind: kind,
            deadline: DispatchTime.now().uptimeNanoseconds + UInt64(lifetime * 1_000_000_000)
        )
    }
}

@Suite("Pass CLI AutoFill secret resolver")
struct PassCLIAutoFillSecretResolverTests {
    @Test("password uses item view and TOTP uses the dedicated command")
    func dispatchesOnlyFixedPassCLICommands() async throws {
        let calls = OSAllocatedUnfairLock(initialState: [[String]]())
        let runner = AutoFillResolverCLIRunner { arguments in
            calls.withLock { $0.append(arguments) }
            if arguments.contains("totp") {
                return Data("{\"totp_uri\":\"otpauth://redacted\",\"totp\":\"246810\"}".utf8)
            }
            return Self.loginItemJSON
        }
        let service = PassCLIService(cliPath: "/fake/pass-cli", runner: runner)
        let resolver = PassCLIAutoFillSecretResolver(cliService: service)
        let descriptor = makeDescriptor(hasTOTP: true)

        let password = try await resolver.resolve(descriptor: descriptor, kind: .password)
        let code = try await resolver.resolve(descriptor: descriptor, kind: .oneTimeCode)

        #expect(password == "not-persisted-password")
        #expect(code == "246810")
        #expect(calls.withLock { $0 } == [
            ["item", "view", "--output", "json", "pass://share/item"],
            ["item", "totp", "--output", "json", "pass://share/item"]
        ])
    }

    private static let loginItemJSON = Data("""
    {
      "item": {
        "id": "item", "share_id": "share", "vault_id": "vault",
        "content": {
          "title": "Example", "note": "", "item_uuid": "item",
          "content": {"Login": {
            "email": "", "username": "person@example.com",
            "password": "not-persisted-password", "urls": ["https://example.com"],
            "totp_uri": "", "passkeys": []
          }},
          "extra_fields": []
        },
        "state": "Active", "flags": [], "create_time": "", "modify_time": ""
      }
    }
    """.utf8)
}

private struct AutoFillResolverCLIRunner: CLIRunning {
    let body: @Sendable ([String]) throws -> Data

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try body(arguments)
    }
}

private struct FakeAutoFillDescriptorStore: AutoFillDescriptorStoring {
    let descriptorValue: AutoFillCredentialDescriptor?
    let candidateValues: [AutoFillCandidate]
    let onLookup: @Sendable () -> Void

    init(
        descriptor: AutoFillCredentialDescriptor?,
        candidates: [AutoFillCandidate] = [],
        onLookup: @escaping @Sendable () -> Void = {}
    ) {
        descriptorValue = descriptor
        candidateValues = candidates
        self.onLookup = onLookup
    }

    func descriptor(id: UUID) async throws -> AutoFillCredentialDescriptor? {
        onLookup()
        guard descriptorValue?.id == id else { return nil }
        return descriptorValue
    }

    func candidates(for query: AutoFillCandidateQuery) async throws -> [AutoFillCandidate] {
        candidateValues
    }
}

private struct SavedAssociation: Equatable, Sendable {
    let service: AutoFillServiceIdentifier
    let descriptorID: UUID
}

private actor FakeAutoFillAppAssociationStore: AutoFillAppAssociationStoring {
    private(set) var saved: [SavedAssociation] = []

    func save(service: AutoFillServiceIdentifier, descriptorID: UUID, createdAt: Date) async throws {
        saved.append(SavedAssociation(service: service, descriptorID: descriptorID))
    }
}

private struct FakeAutoFillSecretResolver: AutoFillSecretResolving {
    let body: @Sendable (AutoFillCredentialDescriptor, AutoFillValueKind) async throws -> String

    init(body: @escaping @Sendable (AutoFillCredentialDescriptor, AutoFillValueKind) async throws -> String) {
        self.body = body
    }

    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind
    ) async throws -> String {
        try await body(descriptor, kind)
    }
}

private func makeDescriptor(hasTOTP: Bool = false) -> AutoFillCredentialDescriptor {
    AutoFillCredentialDescriptor(
        id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        vaultID: "vault",
        itemID: "item",
        shareID: "share",
        title: "Example",
        username: "person@example.com",
        serviceIdentifier: "example.com",
        hasTOTP: hasTOTP
    )
}
