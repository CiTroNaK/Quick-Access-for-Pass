import Darwin
import Foundation
import os
import Testing
@testable import Quick_Access_for_Pass

@Suite("Recent AutoFill password preference")
@MainActor
struct AutoFillRecentPasswordTests {
    @Test("recent-use candidate metadata round trips and is announced in the site picker")
    func recentUseBadge() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "descriptorID": UUID().uuidString, "title": "Example", "username": "person@example.com",
            "kind": "oneTimeCode", "matchTier": 0, "isRecentlyUsed": true
        ])
        let candidate = try JSONDecoder().decode(AutoFillCandidate.self, from: data)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any])
        #expect(encoded["isRecentlyUsed"] as? Bool == true)
        let label = AutoFillCandidatePickerPresentation.accessibilityLabel(for: candidate, in: .siteResults([candidate]))
        #expect(label.contains("Recently used"))
        #expect(label.contains("person@example.com"))
    }

    @Test("ordinary candidates explicitly encode no recent-use preference")
    func ordinaryCandidateMetadata() throws {
        let candidate = AutoFillCandidate(
            descriptorID: UUID(), title: "Example", username: "person@example.com", kind: .oneTimeCode, matchTier: 0
        )
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any])
        #expect(encoded["isRecentlyUsed"] as? Bool == false)
    }

    @Test("recent password delivery prefers a site code only while eligible", arguments: [
        "delivered", "notDelivered", "beforeExpiry", "expired", "revoked", "cleared", "locked",
        "global", "otherSite", "app", "codeDelivery", "failedWrite", "lessSpecific"
    ])
    func recentPasswordPreference(scenario: String) async throws {
        let descriptor = AutoFillCredentialDescriptor(
            id: UUID(), vaultID: "vault", itemID: "item", shareID: "share", title: "Example",
            username: "person@example.com", serviceIdentifier: "example.com", hasTOTP: true
        )
        let otherID = UUID()
        let original = [
            AutoFillCandidate(descriptorID: otherID, title: "Other", username: "other@example.com", kind: .oneTimeCode, matchTier: 0),
            AutoFillCandidate(descriptorID: descriptor.id, title: "Example", username: "person@example.com", kind: .oneTimeCode,
                              matchTier: scenario == "lessSpecific" ? 1 : 0)
        ]
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let locked = OSAllocatedUnfairLock(initialState: false)
        let guardState = SecretReleaseGuard()
        let coordinator = AutoFillBrokerCoordinator(
            descriptorStore: RecentPasswordDescriptorStore(descriptorValue: descriptor, candidateValues: original),
            secretResolver: RecentPasswordResolver(),
            secretReleaseGuard: guardState,
            isAppLocked: { locked.withLock { $0 } },
            showLockedPanel: { _ in false },
            now: { clock.withLock { $0 } }
        )
        let delivery = try await coordinator.resolveDelivery(request: AutoFillRegisteredRequest(
            requestID: UUID(), descriptorID: descriptor.id,
            kind: scenario == "codeDelivery" ? .oneTimeCode : .password, deadline: 30_000_000_000
        ))
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let flags = fcntl(pair[0], F_GETFL, 0)
        try #require(flags >= 0 && fcntl(pair[0], F_SETFL, flags | O_NONBLOCK) == 0)
        if scenario == "failedWrite" {
            await #expect(throws: (any Swift.Error).self) {
                try await delivery.release.deliver(delivery.value, toFileDescriptor: -1)
            }
        } else if scenario != "notDelivered" {
            try await delivery.release.deliver(delivery.value, toFileDescriptor: pair[0])
            _ = try AutoFillWire.readMessage(AutoFillBrokerResponse.self, fromFileDescriptor: pair[1])
        }
        if scenario == "beforeExpiry" { clock.withLock { $0 += 119_999_999_999 } }
        if scenario == "expired" { clock.withLock { $0 += 120_000_000_000 } }
        if scenario == "cleared" { coordinator.clearRecentPasswordSelection() }
        if scenario == "revoked" { guardState.revoke() }
        if scenario == "locked" { locked.withLock { $0 = true } }
        let deadline = clock.withLock { $0 + 30_000_000_000 }
        let query: AutoFillCandidateQuery = scenario == "global"
            ? .global(requestID: UUID(), search: "Example", kind: .oneTimeCode, deadlineUptimeNanoseconds: deadline)
            : .site(requestID: UUID(), services: [try AutoFillServiceIdentifier(
                kind: scenario == "app" ? .app : .domain,
                identifier: scenario == "otherSite" ? "other.example" : "example.com", displayName: nil
            )], kind: .oneTimeCode, deadlineUptimeNanoseconds: deadline)

        let candidates = try await coordinator.listCandidates(query: query)

        let isRecent = ["delivered", "beforeExpiry", "lessSpecific"].contains(scenario)
        #expect(candidates.map(\.descriptorID) == (["delivered", "beforeExpiry"].contains(scenario)
            ? [descriptor.id, otherID] : [otherID, descriptor.id]))
        #expect(candidates.filter(\.isRecentlyUsed).map(\.descriptorID) == (isRecent ? [descriptor.id] : []))
        #expect(candidates.count == 2)
    }
}

private struct RecentPasswordDescriptorStore: AutoFillDescriptorStoring {
    let descriptorValue: AutoFillCredentialDescriptor
    let candidateValues: [AutoFillCandidate]

    func descriptor(id: UUID) async throws -> AutoFillCredentialDescriptor? {
        descriptorValue.id == id ? descriptorValue : nil
    }

    func candidates(for query: AutoFillCandidateQuery) async throws -> [AutoFillCandidate] {
        candidateValues
    }
}

private struct RecentPasswordResolver: AutoFillSecretResolving {
    func resolve(
        descriptor: AutoFillCredentialDescriptor, kind: AutoFillValueKind, context: SecretResolutionContext
    ) async throws -> ResolvedSecret<String> {
        ResolvedSecret(value: "synthetic-value", offlineCapability: nil)
    }
}
