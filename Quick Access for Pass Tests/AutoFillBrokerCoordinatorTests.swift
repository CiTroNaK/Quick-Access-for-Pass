import Darwin
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
        let clock = ManualDeadlineClock()
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
            showLockedPanel: { _ in Issue.record("Unlocked requests must not show the panel"); return false },
            now: { clock.now },
            deadlineSleep: { try await clock.sleep(for: $0) }
        )

        let result = try await coordinator.resolve(request: AutoFillRegisteredRequest(
            requestID: UUID(), descriptorID: descriptor.id, kind: .password, deadline: 3_000_000_000
        ))

        #expect(result.value == "resolved-password")
        #expect(events.withLock { $0 } == ["descriptor", "resolver", "descriptor"])
    }

    @Test("locked request waits for unlock with only remaining time, then resolves TOTP")
    @MainActor
    func lockedRequestUsesRemainingDeadline() async throws {
        let descriptor = makeDescriptor(hasTOTP: true)
        let request = makeRequest(kind: .oneTimeCode, lifetime: ordinaryPathLifetime)
        let initialNow = request.deadline - UInt64(ordinaryPathLifetime * 1_000_000_000)
        let clock = OSAllocatedUnfairLock(initialState: initialNow)
        let observedTimeout = OSAllocatedUnfairLock<Double?>(initialState: nil)
        let states = OSAllocatedUnfairLock(initialState: [AutoFillRequestState]())
        let locked = OSAllocatedUnfairLock(initialState: true)
        // Test remaining-budget forwarding, not whether an unrelated MainActor
        // workload happens to fit inside a one-second successful-path fixture.
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor) {
                clock.withLock { $0 = initialNow + 5_000_000_000 }
            },
            secretResolver: FakeAutoFillSecretResolver { _, kind in
                #expect(kind == .oneTimeCode)
                return "123456"
            },
            isAppLocked: { locked.withLock { $0 } },
            showLockedPanel: { timeout in
                observedTimeout.withLock { $0 = timeout }
                locked.withLock { $0 = false }
                return true
            },
            now: { clock.withLock { $0 } }
        )

        let result = try await coordinator.resolve(
            request: request,
            transition: { state in states.withLock { $0.append(state) } }
        )

        #expect(result.value == "123456")
        #expect(states.withLock { $0 } == [.awaitingUnlock, .resolving])
        let timeout = try #require(observedTimeout.withLock { $0 })
        // A reset to the original budget now fails deterministically.
        #expect(timeout == ordinaryPathLifetime - 5)
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

        #expect(value.value == "resolved")
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

}

extension AutoFillBrokerCoordinatorTests {
    @Test("selected encrypted TOTP snapshot bypasses a stalling native adapter")
    @MainActor
    func cachedTOTPBypassesNativeStallWithinOriginalDeadline() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let totpURI = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999"
        let snapshotCodec = fixture.codec()
        let service = OfflineModeService(repository: fixture.repository, codec: snapshotCodec, cliService: BrokerSnapshotViewer(totp: totpURI))
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let resolver = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            cliService: PassCLIService(runner: NativeStallingCLIRunner()),
            repository: fixture.repository, codec: snapshotCodec, readiness: service
        ))
        let descriptor = makeDescriptor(hasTOTP: true)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor), secretResolver: resolver,
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )
        let request = AutoFillRegisteredRequest(
            requestID: UUID(), descriptorID: descriptor.id, kind: .oneTimeCode,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        )

        let start = ContinuousClock.now
        let value = try await coordinator.resolve(request: request)
        #expect(value.value.count == 8)
        #expect(start.duration(to: .now) < .seconds(4.5))
    }

    @Test("original deadline rejects cached TOTP when decode expires it")
    @MainActor
    func cachedTOTPDecodeHonorsOriginalDeadline() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let totpURI = "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&period=999999999"
        let snapshotCodec = fixture.codec()
        let service = OfflineModeService(repository: fixture.repository, codec: snapshotCodec, cliService: BrokerSnapshotViewer(totp: totpURI))
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        let clock = OSAllocatedUnfairLock(initialState: DispatchTime.now().uptimeNanoseconds)
        let originalDeadline = clock.withLock { $0 + 5_000_000_000 }
        let codec = DeadlineAdvancingBrokerCodec(codec: snapshotCodec, clock: clock, deadline: originalDeadline)
        let resolver = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            live: PassCLIService(runner: NativeStallingCLIRunner()),
            repository: fixture.repository, codec: codec, readiness: service, now: { clock.withLock { $0 } }
        ))
        let descriptor = makeDescriptor(hasTOTP: true)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor), secretResolver: resolver,
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )
        let request = AutoFillRegisteredRequest(
            requestID: UUID(), descriptorID: descriptor.id, kind: .oneTimeCode, deadline: originalDeadline
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.deadlineExpired) {
            _ = try await coordinator.resolve(request: request)
        }
        #expect(await codec.decodeCount() == 1)
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test("no-cache native stall terminates within the broker's original deadline")
    @MainActor
    func noCacheNativeStallHonorsOriginalDeadline() async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let snapshotCodec = fixture.codec()
        let service = OfflineModeService(repository: fixture.repository, codec: snapshotCodec, cliService: BrokerSnapshotViewer())
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        try await fixture.repository.removeItem("item")
        let live = PassCLIService(runner: NativeStallingCLIRunner())
        let resolver = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            cliService: live, repository: fixture.repository, codec: snapshotCodec, readiness: service
        ))
        let descriptor = makeDescriptor()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor), secretResolver: resolver,
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )
        let request = AutoFillRegisteredRequest(
            requestID: UUID(), descriptorID: descriptor.id, kind: .password,
            deadline: DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        )

        let start = ContinuousClock.now
        await #expect { _ = try await coordinator.resolve(request: request) } throws: { error in
            if let error = error as? CLIError, case .timeout = error { return true }
            return (error as? AutoFillBrokerCoordinator.Error) == .deadlineExpired
        }
        #expect(start.duration(to: .now) < .seconds(5.5))
        #expect(fixture.repository.releaseAuthority.registrationCount == 0)
    }

    @Test("external cancellation of a composed native live stall releases no snapshot value", arguments: [AutoFillValueKind.password, .oneTimeCode])
    @MainActor
    func composedNativeStallCancellationCleansUpWithoutFallback(kind: AutoFillValueKind) async throws {
        let fixture = try OfflineLifecycleFixture(itemIDs: ["item"])
        let item = try #require(fixture.items.first)
        let snapshotCodec = fixture.codec()
        let service = OfflineModeService(
            repository: fixture.repository, codec: snapshotCodec,
            cliService: BrokerSnapshotViewer(totp: "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8")
        )
        try await initializeOfflineFixtureService(service)
        try await service.makeAvailableOffline(item: item, shareId: "share")
        try await fixture.repository.removeItem("item")
        let codec = BrokerDecodeCountingCodec(codec: snapshotCodec)
        let started = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-native-stall-\(UUID().uuidString).started")
        defer { try? FileManager.default.removeItem(at: started) }
        let live = PassCLIService(runner: NativeStallingCLIRunner(startedMarker: started))
        let resolver = OfflineAutoFillSecretResolver(resolver: OfflineSecretResolver(
            cliService: live, repository: fixture.repository, codec: codec, readiness: service
        ))
        let descriptor = makeDescriptor(hasTOTP: true)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor), secretResolver: resolver,
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )
        let request = AutoFillRegisteredRequest(
            requestID: UUID(), descriptorID: descriptor.id, kind: kind,
            deadline: DispatchTime.now().uptimeNanoseconds + 20_000_000_000
        )
        let task = Task { @MainActor in try await coordinator.resolve(request: request) }
        do {
            try await waitForNativeStart(at: started)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await codec.decodeCount() == 0)
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    @Test("broker forwards original deadline and verified username to the resolver")
    @MainActor
    func brokerForwardsResolutionContext() async throws {
        let descriptor = makeDescriptor()
        let recorded = OSAllocatedUnfairLock<SecretResolutionContext?>(initialState: nil)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor),
            secretResolver: ContextRecordingResolver(recorded: recorded),
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )
        let request = makeRequest(kind: .password, lifetime: ordinaryPathLifetime)
        _ = try await coordinator.resolve(request: request)
        let context = try #require(recorded.withLock { $0 })
        #expect(context.deadlineUptimeNanoseconds == request.deadline)
        #expect(context.expectedUsername == descriptor.username)
    }

    @Test("revoking the shared guard while resolution is suspended releases no broker value")
    @MainActor
    func guardRevocationRejectsBlockedBrokerResolution() async throws {
        let guardState = SecretReleaseGuard()
        let gate = OfflineTestGate()
        let descriptor = makeDescriptor()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor),
            secretResolver: GatedBrokerResolver(gate: gate),
            secretReleaseGuard: guardState,
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )
        let task = Task { @MainActor in
            try await coordinator.resolve(request: makeRequest(kind: .password, lifetime: ordinaryPathLifetime))
        }
        do {
            try await gate.waitUntilEntered()
            guardState.revoke()
            await gate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test("final descriptor removal rejects a resolved value")
    @MainActor
    func finalDescriptorRemovalRejectsResolvedValue() async throws {
        let descriptor = makeDescriptor()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: SequencedDescriptorStore(values: [descriptor, nil]),
            secretResolver: FakeAutoFillSecretResolver { _, _ in "must-not-release" },
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.descriptorNotFound) {
            _ = try await coordinator.resolve(request: makeRequest(kind: .password, lifetime: ordinaryPathLifetime))
        }
    }

    @Test("final descriptor identity change rejects a resolved password")
    @MainActor
    func finalDescriptorIdentityChangeRejectsResolvedValue() async throws {
        let descriptor = makeDescriptor()
        let changedIdentity = AutoFillCredentialDescriptor(
            id: descriptor.id, vaultID: descriptor.vaultID, itemID: descriptor.itemID,
            shareID: descriptor.shareID, title: descriptor.title, username: "replacement@example.com",
            serviceIdentifier: descriptor.serviceIdentifier, hasTOTP: descriptor.hasTOTP
        )
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: SequencedDescriptorStore(values: [descriptor, changedIdentity]),
            secretResolver: FakeAutoFillSecretResolver { _, _ in "must-not-release" },
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.descriptorNotFound) {
            _ = try await coordinator.resolve(request: makeRequest(kind: .password, lifetime: ordinaryPathLifetime))
        }
    }

    @Test("final descriptor capability change rejects a cached TOTP value")
    @MainActor
    func finalDescriptorCapabilityChangeRejectsTOTPCachedValue() async throws {
        let descriptor = makeDescriptor(hasTOTP: true)
        let removedCapability = AutoFillCredentialDescriptor(
            id: descriptor.id, vaultID: descriptor.vaultID, itemID: descriptor.itemID,
            shareID: descriptor.shareID, title: descriptor.title, username: descriptor.username,
            serviceIdentifier: descriptor.serviceIdentifier, hasTOTP: false
        )
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: SequencedDescriptorStore(values: [descriptor, removedCapability]),
            secretResolver: FakeAutoFillSecretResolver { _, _ in "must-not-release" },
            isAppLocked: { false }, showLockedPanel: { _ in false }
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.descriptorNotFound) {
            _ = try await coordinator.resolve(request: makeRequest(kind: .oneTimeCode, lifetime: ordinaryPathLifetime))
        }
    }

    @Test("descriptor removal after unlock prevents the authorization recheck release")
    @MainActor
    func descriptorRemovalAfterUnlockRejectsBeforeRelease() async throws {
        let descriptor = makeDescriptor()
        let locked = OSAllocatedUnfairLock(initialState: true)
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: SequencedDescriptorStore(values: [descriptor, nil]),
            secretResolver: FakeAutoFillSecretResolver { _, _ in "must-not-release" },
            isAppLocked: { locked.withLock { $0 } },
            showLockedPanel: { _ in
                locked.withLock { $0 = false }
                return true
            }
        )

        await #expect(throws: AutoFillBrokerCoordinator.Error.descriptorNotFound) {
            _ = try await coordinator.resolve(request: makeRequest(kind: .password, lifetime: ordinaryPathLifetime))
        }
    }

    @Test("final delivery rechecks original identity, capability, deadline, and consumes the release once")
    @MainActor
    func finalDeliveryIsSingleUseAndNeverRebaselinesDescriptor() async throws {
        let descriptor = makeDescriptor(hasTOTP: true)
        let request = AutoFillRegisteredRequest(
            requestID: UUID(), descriptorID: descriptor.id, kind: .oneTimeCode,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        )
        let store = SequencedDescriptorStore(values: [nil])
        let guardState = SecretReleaseGuard()
        let release = AutoFillCredentialRelease(
            request: request, descriptor: descriptor, releaseToken: guardState.capture(),
            descriptorStore: store, secretReleaseGuard: guardState,
            isAppLocked: { false }, now: { DispatchTime.now().uptimeNanoseconds }
        )
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        defer { close(pair[0]); close(pair[1]) }

        await #expect(throws: AutoFillBrokerCoordinator.Error.descriptorNotFound) {
            try await release.deliver(ResolvedSecret(value: "must-not-release", offlineCapability: nil), toFileDescriptor: pair[0])
        }
        // A failed final read consumes the request capability; a later metadata
        // value cannot establish a new identity baseline or release a second frame.
        await #expect(throws: CancellationError.self) {
            try await release.deliver(ResolvedSecret(value: "must-not-release", offlineCapability: nil), toFileDescriptor: pair[0])
        }
    }

    @Test("expired final delivery never starts its metadata read")
    @MainActor
    func expiredFinalDeliverySkipsDescriptorLookup() async throws {
        let descriptor = makeDescriptor()
        let store = CountingDescriptorStore(descriptor: descriptor)
        let guardState = SecretReleaseGuard()
        let request = AutoFillRegisteredRequest(
            requestID: UUID(), descriptorID: descriptor.id, kind: .password, deadline: 100
        )
        let release = AutoFillCredentialRelease(
            request: request, descriptor: descriptor, releaseToken: guardState.capture(),
            descriptorStore: store, secretReleaseGuard: guardState,
            isAppLocked: { false }, now: { 100 }
        )
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        defer { close(pair[0]); close(pair[1]) }

        await #expect(throws: AutoFillBrokerCoordinator.Error.deadlineExpired) {
            try await release.deliver(ResolvedSecret(value: "must-not-release", offlineCapability: nil), toFileDescriptor: pair[0])
        }
        #expect(await store.lookupCount() == 0)
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
    private var ordinaryPathLifetime: TimeInterval { 30 }

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

        #expect(password.value == "not-persisted-password")
        #expect(code.value == "246810")
        #expect(calls.withLock { $0 } == [
            ["item", "view", "--output", "json", "pass://share/item"],
            ["item", "view", "--output", "json", "pass://share/item"],
            ["item", "totp", "--output", "json", "pass://share/item"]
        ])
    }

    @Test("live-only TOTP forwards one original absolute deadline to both commands")
    func totpForwardsOriginalDeadlineWithoutReset() async throws {
        let runner = DeadlineRecordingAutoFillResolverCLIRunner()
        let resolver = PassCLIAutoFillSecretResolver(cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner))
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        let context = SecretResolutionContext(
            deadlineUptimeNanoseconds: deadline.uptimeNanoseconds,
            expectedUsername: "person@example.com"
        )

        #expect(try await resolver.resolve(descriptor: makeDescriptor(hasTOTP: true), kind: .oneTimeCode, context: context).value == "246810")
        #expect(runner.observedDeadlines() == [deadline, deadline])
    }

    @Test("TOTP cancellation while the second native call is active returns no value")
    func totpCancellationBeforeSecondCallReturnsCancelsResolution() async throws {
        let gate = OfflineTestGate()
        let runner = GatedTOTPCLIRunner(gate: gate, login: Self.loginItemJSON)
        let resolver = PassCLIAutoFillSecretResolver(cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner))
        let task = Task {
            try await resolver.resolve(descriptor: makeDescriptor(hasTOTP: true), kind: .oneTimeCode)
        }
        do {
            try await gate.waitUntilEntered()
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test("TOTP expiry between native calls never starts the second command")
    func totpExpiryBetweenCallsPreventsSecondCommand() async throws {
        let deadline: UInt64 = 5_000_000_000
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let runner = AutoFillResolverCLIRunner(now: { clock.withLock { $0 } }) { arguments in
            calls.withLock { $0 += 1 }
            if arguments.contains("view") { clock.withLock { $0 = deadline } }
            return arguments.contains("totp")
                ? Data("{\"totp_uri\":\"otpauth://redacted\",\"totp\":\"246810\"}".utf8)
                : Self.loginItemJSON
        }
        let resolver = PassCLIAutoFillSecretResolver(
            cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner),
            now: { clock.withLock { $0 } }
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline, expectedUsername: "person@example.com")

        var returnedValue = false
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolve(descriptor: makeDescriptor(hasTOTP: true), kind: .oneTimeCode, context: context)
            returnedValue = true
        }
        #expect(returnedValue == false)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("TOTP expiry after the second native response never releases its value")
    func totpExpiryBeforeValueReleaseRejectsReturnedCode() async throws {
        let deadline: UInt64 = 5_000_000_000
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let runner = AutoFillResolverCLIRunner(now: { clock.withLock { $0 } }) { arguments in
            calls.withLock { $0 += 1 }
            if arguments.contains("totp") { clock.withLock { $0 = deadline } }
            return arguments.contains("totp")
                ? Data("{\"totp_uri\":\"otpauth://redacted\",\"totp\":\"246810\"}".utf8)
                : Self.loginItemJSON
        }
        let resolver = PassCLIAutoFillSecretResolver(
            cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner),
            now: { clock.withLock { $0 } }
        )
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline, expectedUsername: "person@example.com")

        var returnedValue = false
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolve(descriptor: makeDescriptor(hasTOTP: true), kind: .oneTimeCode, context: context)
            returnedValue = true
        }
        #expect(returnedValue == false)
        #expect(calls.withLock { $0 } == 2)
    }

    fileprivate static let loginItemJSON = Data("""
    {
      "item": {
        "id": "item", "share_id": "share", "vault_id": "vault",
        "content": {
          "title": "Example", "note": "", "item_uuid": "item",
          "content": {"Login": {
            "email": "", "username": "person@example.com",
            "password": "not-persisted-password", "urls": ["https://example.com"],
            "totp_uri": "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "passkeys": []
          }},
          "extra_fields": []
        },
        "state": "Active", "flags": [], "create_time": "", "modify_time": ""
      }
    }
    """.utf8)
}

private struct AutoFillResolverCLIRunner: CLIRunning {
    private let now: @Sendable () -> UInt64
    let body: @Sendable ([String]) throws -> Data

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         body: @escaping @Sendable ([String]) throws -> Data) {
        self.now = now
        self.body = body
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try body(arguments)
    }

    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        let remaining = try deadline.remainingSeconds(at: now())
        return try await run(executablePath: executablePath, arguments: arguments, timeout: remaining, maximumOutputBytes: maximumOutputBytes)
    }
}

private struct DeadlineRecordingAutoFillResolverCLIRunner: CLIRunning {
    private let deadlines = OSAllocatedUnfairLock<[CLIExecutionDeadline]>(initialState: [])

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try response(arguments)
    }

    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        deadlines.withLock { $0.append(deadline) }
        return try response(arguments)
    }

    func observedDeadlines() -> [CLIExecutionDeadline] { deadlines.withLock { $0 } }

    private func response(_ arguments: [String]) throws -> Data {
        if arguments.contains("totp") { return Data("{\"totp_uri\":\"otpauth://redacted\",\"totp\":\"246810\"}".utf8) }
        return PassCLIAutoFillSecretResolverTests.loginItemJSON
    }
}

private actor GatedTOTPCLIRunner: CLIRunning {
    let gate: OfflineTestGate
    let login: Data

    init(gate: OfflineTestGate, login: Data) {
        self.gate = gate
        self.login = login
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        if arguments.contains("totp") {
            try await gate.wait()
            return Data("{\"totp_uri\":\"otpauth://redacted\",\"totp\":\"246810\"}".utf8)
        }
        return login
    }
}

private struct TimedAutoFillResolverCLIRunner: CLIRunning {
    let body: @Sendable ([String], TimeInterval) throws -> Data

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try body(arguments, timeout)
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

private actor CountingDescriptorStore: AutoFillDescriptorStoring {
    private let descriptorValue: AutoFillCredentialDescriptor
    private var count = 0

    init(descriptor: AutoFillCredentialDescriptor) { descriptorValue = descriptor }

    func descriptor(id: UUID) async throws -> AutoFillCredentialDescriptor? {
        count += 1
        return id == descriptorValue.id ? descriptorValue : nil
    }

    func lookupCount() -> Int { count }
}

private actor SequencedDescriptorStore: AutoFillDescriptorStoring {
    private var values: [AutoFillCredentialDescriptor?]

    init(values: [AutoFillCredentialDescriptor?]) { self.values = values }

    func descriptor(id: UUID) async throws -> AutoFillCredentialDescriptor? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private actor GatedBrokerResolver: AutoFillSecretResolving {
    private let gate: OfflineTestGate

    init(gate: OfflineTestGate) { self.gate = gate }

    func resolve(
        descriptor: AutoFillCredentialDescriptor,
        kind: AutoFillValueKind,
        context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String> {
        try? await gate.wait()
        return ResolvedSecret(value: "must-not-release", offlineCapability: nil)
    }
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
        kind: AutoFillValueKind,
        context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String> {
        return ResolvedSecret(value: try await body(descriptor, kind), offlineCapability: nil)
    }
}

private struct ContextRecordingResolver: AutoFillSecretResolving {
    let recorded: OSAllocatedUnfairLock<SecretResolutionContext?>

    func resolve(descriptor: AutoFillCredentialDescriptor, kind: AutoFillValueKind, context: SecretResolutionContext) async throws -> ResolvedSecret<String> {
        recorded.withLock { $0 = context }
        return ResolvedSecret(value: "resolved", offlineCapability: nil)
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

private struct BrokerSnapshotViewer: OfflineItemViewing {
    let totp: String

    init(totp: String = "") { self.totp = totp }

    func viewItem(itemId: String, shareId: String) async throws -> CLIItem {
        try offlineTestCLIItem(
            id: itemId, vaultID: "vault", shareID: shareId,
            password: "cached-password", username: "person@example.com", totp: totp
        )
    }
}

private actor DeadlineAdvancingBrokerCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private let clock: OSAllocatedUnfairLock<UInt64>
    private let deadline: UInt64
    private var decodes = 0

    init(codec: OfflineSnapshotCodec, clock: OSAllocatedUnfairLock<UInt64>, deadline: UInt64) {
        self.codec = codec
        self.clock = clock
        self.deadline = deadline
    }

    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        decodes += 1
        let item = try await codec.decodeSnapshot(snapshot)
        clock.withLock { $0 = deadline }
        return item
    }

    func decodeCount() -> Int { decodes }
}

private actor BrokerDecodeCountingCodec: OfflineSnapshotCoding {
    private let codec: OfflineSnapshotCodec
    private var decodes = 0

    init(codec: OfflineSnapshotCodec) { self.codec = codec }

    func prepareSnapshot(from item: CLIItem, for request: OfflineRequestToken) async throws -> EncryptedOfflineSnapshot {
        try await codec.prepareSnapshot(from: item, for: request)
    }

    func decodeSnapshot(_ snapshot: EncryptedOfflineSnapshot) async throws -> CLIItem {
        decodes += 1
        return try await codec.decodeSnapshot(snapshot)
    }

    func decodeCount() -> Int { decodes }
}

/// This runner is intentionally not a completion fake: each PassCLIService
/// timed call delegates to the production bounded native runner with a finite
/// `exec sleep` process, preserving the composed native lifecycle under test.
private struct NativeStallingCLIRunner: CLIRunning {
    let startedMarker: URL?

    init(startedMarker: URL? = nil) { self.startedMarker = startedMarker }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await run(executablePath: executablePath, arguments: arguments, timeout: timeout, maximumOutputBytes: 1024)
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        let marker = startedMarker.map { "printf started > '\($0.path)'; " } ?? ""
        return try await CLIRunner.run(
            executablePath: "/bin/sh", arguments: ["-c", "\(marker)exec /bin/sleep 10"],
            timeout: timeout, maximumOutputBytes: maximumOutputBytes
        )
    }
}

private func waitForNativeStart(at marker: URL) async throws {
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileNoSuchFile)
}

extension AutoFillBrokerCoordinatorTests {
    @Test("Unlock watchdog expires at the original logical deadline without secret resolution")
    @MainActor
    func unlockExpiresOnControlledClock() async throws {
        let clock = ManualDeadlineClock()
        let gate = OfflineTestGate()
        let didResolve = OSAllocatedUnfairLock(initialState: false)
        let descriptor = makeDescriptor()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: FakeAutoFillDescriptorStore(descriptor: descriptor),
            secretResolver: FakeAutoFillSecretResolver { _, _ in
                didResolve.withLock { $0 = true }
                return "must-not-release"
            },
            isAppLocked: { true },
            showLockedPanel: { _ in try? await gate.wait(); return true },
            now: { clock.now },
            deadlineSleep: { try await clock.sleep(for: $0) }
        )
        let task = Task {
            try await coordinator.resolve(request: AutoFillRegisteredRequest(
                requestID: UUID(), descriptorID: descriptor.id, kind: .password, deadline: 3_000_000_000
            ))
        }
        defer { task.cancel() }
        try await gate.waitUntilEntered()
        let registered = await waitForTestCondition { clock.pendingSleepCount == 1 }
        try #require(registered)

        clock.advance(to: 3_000_000_000)
        await #expect(throws: AutoFillBrokerCoordinator.Error.deadlineExpired) { try await task.value }

        #expect(!didResolve.withLock { $0 })
        #expect(clock.pendingSleepCount == 0)
    }
}
