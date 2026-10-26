import Foundation
import Synchronization
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder-derived release authority ordering")
struct OfflineFolderReleaseRaceTests {
    @Test("Removing covering policies cumulatively revokes bound and pre-bind releases", arguments: [false, true])
    func overlappingPolicies(preBind: Bool) async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        _ = try await fixture.select("child")
        try await fixture.cache(parent)
        let snapshot = try #require(try await fixture.snapshot())
        let authority = fixture.repository.releaseAuthority
        let capture = authority.capture(for: fixture.key())
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        if !preBind { try authority.bind(capture, proof: proof) }
        _ = try await fixture.select("parent", selected: false)
        if preBind { try authority.bind(capture, proof: proof) }
        let current = try #require(try await fixture.repository.releaseProof(for: snapshot))
        let capability = try authority.authorize(capture, proof: current)
        #expect(try capability.withRelease(validating: {}, effect: { true }))
        // Use a new, still-unconsumed capability for the final covering removal.
        let finalCapture = authority.capture(for: fixture.key())
        try authority.bind(finalCapture, proof: current)
        let finalCapability = try authority.authorize(finalCapture, proof: current)
        _ = try await fixture.select("child", selected: false)
        #expect(throws: OfflineReleaseError.revoked) {
            try finalCapability.withRelease(validating: {}, effect: {})
        }
        #expect(try await fixture.snapshot() == nil)
    }

    @Test("Whole-vault deselection does not revoke folder-authorized delivery")
    func vaultRemoval() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        try await fixture.cache(parent)
        let snapshot = try #require(try await fixture.snapshot())
        let capture = fixture.repository.releaseAuthority.capture(for: fixture.key())
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        try fixture.repository.releaseAuthority.bind(capture, proof: proof)
        let capability = try fixture.repository.releaseAuthority.authorize(capture, proof: proof)
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        #expect(try capability.withRelease(validating: {}, effect: { true }))
        #expect(try await fixture.snapshot() != nil)
    }

    @Test("A hierarchy move invalidates before queued SQL; independent child coverage survives", arguments: [false, true])
    func queuedMove(independentChild: Bool) async throws {
        let enabled = Mutex(false)
        let pause = IncrementalSyncGate()
        let fixture = try OfflineFolderFixture(testing: .init(afterAdmission: { scope in
            if case .replaceMetadata = scope, enabled.withLock({ $0 }) { await pause.wait() }
        }))
        try await fixture.synchronize()
        let parent = try #require(try await fixture.select("parent"))
        if independentChild { _ = try await fixture.select("child") }
        try await fixture.cache(parent)
        let snapshot = try #require(try await fixture.snapshot())
        let authority = fixture.repository.releaseAuthority
        let capture = authority.capture(for: fixture.key())
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        try authority.bind(capture, proof: proof)
        let capability = try authority.authorize(capture, proof: proof)
        let preBind = authority.capture(for: fixture.key())
        enabled.withLock { $0 = true }
        let task = Task { try await fixture.synchronize(childParent: nil) }
        await pause.waitUntilEntered()
        if independentChild {
            try authority.bind(preBind, proof: proof)
            #expect(try capability.withRelease(validating: {}, effect: { true }))
        } else {
            #expect(throws: OfflineReleaseError.revoked) { try authority.bind(preBind, proof: proof) }
            #expect(throws: OfflineReleaseError.revoked) { try capability.withRelease(validating: {}, effect: {}) }
        }
        await pause.open()
        try await task.value
        #expect((try await fixture.snapshot() != nil) == independentChild)
    }

    @Test("Rollback retains committed coverage and allows a fresh guarded release")
    func rollback() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent)
        await #expect(throws: ForcedFailure.rollback) {
            try await fixture.synchronize(childParent: nil, beforeDescriptorWrite: { throw ForcedFailure.rollback })
        }
        let snapshot = try #require(try await fixture.snapshot())
        let authority = fixture.repository.releaseAuthority
        let capture = authority.capture(for: fixture.key())
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        try authority.bind(capture, proof: proof)
        let capability = try authority.authorize(capture, proof: proof)
        #expect(try capability.withRelease(validating: {}, effect: { true }))
    }

    @Test("Two removals revoke a capability authorized before either mutation")
    func cumulativeRemovals() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        _ = try await fixture.select("child")
        try await fixture.cache(parent)
        let snapshot = try #require(try await fixture.snapshot())
        let authority = fixture.repository.releaseAuthority
        let capture = authority.capture(for: fixture.key())
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        try authority.bind(capture, proof: proof)
        let capability = try authority.authorize(capture, proof: proof)
        _ = try await fixture.select("parent", selected: false)
        _ = try await fixture.select("child", selected: false)
        #expect(throws: OfflineReleaseError.revoked) { try capability.withRelease(validating: {}, effect: {}) }
    }

    @Test("A committed independent coverage gain preserves an existing capability", arguments: [false, true])
    func committedCoverageGain(vault: Bool) async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent)
        let snapshot = try #require(try await fixture.snapshot())
        let authority = fixture.repository.releaseAuthority
        let capture = authority.capture(for: fixture.key())
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        try authority.bind(capture, proof: proof)
        let capability = try authority.authorize(capture, proof: proof)
        if vault { _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault") }
        else { _ = try await fixture.select("child") }
        _ = try await fixture.select("parent", selected: false)
        #expect(try capability.withRelease(validating: {}, effect: { true }))
    }

    @Test("A re-selection commit cannot erase overlapping pending revocations", arguments: [false, true])
    func pendingRevocationsSurviveGain(preBind: Bool) async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        _ = try await fixture.select("child")
        try await fixture.cache(parent)
        let snapshot = try #require(try await fixture.snapshot())
        let authority = fixture.repository.releaseAuthority
        let capture = authority.capture(for: fixture.key())
        let proof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        let capability: OfflineReleaseCapability?
        if preBind { capability = nil }
        else { try authority.bind(capture, proof: proof); capability = try authority.authorize(capture, proof: proof) }
        let first = authority.beginMutation(.folderOnly(vaultID: "vault", folderID: "parent"))
        _ = try await fixture.select("parent")
        let second = authority.beginMutation(.folderOnly(vaultID: "vault", folderID: "child"))
        if let capability {
            #expect(throws: OfflineReleaseError.revoked) { try capability.withRelease(validating: {}, effect: {}) }
        } else {
            #expect(throws: OfflineReleaseError.revoked) { try authority.bind(capture, proof: proof) }
        }
        authority.finishMutation(first, outcome: .rolledBack)
        authority.finishMutation(second, outcome: .rolledBack)
        #expect(try await fixture.snapshot() != nil)
    }

    @Test("Pre-bind permission gains coalesce without losing an independently surviving source")
    func coalescedPreBindGains() async throws {
        let fixture = try await OfflineFolderFixture.make()
        let parent = try #require(try await fixture.select("parent"))
        try await fixture.cache(parent)
        let snapshot = try #require(try await fixture.snapshot())
        let authority = fixture.repository.releaseAuthority
        let capture = authority.capture(for: fixture.key())
        let oldProof = try #require(try await fixture.repository.releaseProof(for: snapshot))
        _ = try await fixture.select("child")
        _ = try await fixture.repository.setVaultSelected(true, vaultID: "vault")
        _ = try await fixture.select("parent", selected: false)
        _ = try await fixture.repository.setVaultSelected(false, vaultID: "vault")
        try authority.bind(capture, proof: oldProof)
        let current = try #require(try await fixture.repository.releaseProof(for: snapshot))
        let capability = try authority.authorize(capture, proof: current)
        #expect(try capability.withRelease(validating: {}, effect: { true }))
    }

    private enum ForcedFailure: Error, Equatable { case rollback }
}
