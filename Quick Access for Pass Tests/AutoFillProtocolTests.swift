import Darwin
import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill broker protocol")
struct AutoFillProtocolTests {
    private let requestID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let descriptorID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let wakeHandle = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    @Test("candidate requests round trip for every service identifier kind", arguments: AutoFillServiceIdentifierKind.allCases)
    func candidateRequestsRoundTrip(kind: AutoFillServiceIdentifierKind) throws {
        let identifier = switch kind {
        case .domain: "login.example.com"
        case .url: "https://login.example.com/sign-in"
        case .app: "com.example.App"
        }
        let service = try AutoFillServiceIdentifier(kind: kind, identifier: identifier, displayName: "Example")
        let request = AutoFillBrokerRequest.listCandidates(.site(
            requestID: requestID,
            services: [service],
            kind: .password,
            deadlineUptimeNanoseconds: 42_000_000_000,
            wakeHandle: wakeHandle
        ))

        #expect(try roundTrip(request, as: AutoFillBrokerRequest.self) == request)
    }

    @Test("global candidate requests retain optional wake handles in protocol version two")
    func globalCandidateRequestRoundTripsWithWakeHandle() throws {
        #expect(AutoFillWire.protocolVersion == 2)
        let request = AutoFillBrokerRequest.listCandidates(.global(
            requestID: requestID,
            search: "example",
            kind: .password,
            deadlineUptimeNanoseconds: 42_000_000_000,
            wakeHandle: wakeHandle
        ))
        #expect(try roundTrip(request, as: AutoFillBrokerRequest.self) == request)
    }

    @Test("version-two wire messages retain their exact Codable contract")
    func versionTwoWireMessagesRetainCodableContract() throws {
        let request = AutoFillBrokerRequest.resolveCredential(
            requestID: requestID,
            descriptorID: descriptorID,
            valueKind: .password,
            deadlineUptimeNanoseconds: 42_000_000_000,
            wakeHandle: wakeHandle
        )
        let decodedRequest = try AutoFillWire.decodeMessage(
            AutoFillBrokerRequest.self,
            from: AutoFillWire.encodeMessage(request)
        )
        guard case let .resolveCredential(
            decodedRequestID,
            decodedDescriptorID,
            decodedValueKind,
            decodedDeadline,
            decodedWakeHandle,
            _
        ) = decodedRequest else {
            Issue.record("Expected a credential resolution request")
            return
        }
        #expect(decodedRequestID == requestID)
        #expect(decodedDescriptorID == descriptorID)
        #expect(decodedValueKind == .password)
        #expect(decodedDeadline == 42_000_000_000)
        #expect(decodedWakeHandle == wakeHandle)

        let candidate = AutoFillCandidate(
            descriptorID: descriptorID,
            title: "Example login",
            username: "person@example.com",
            kind: .password,
            matchTier: 0
        )
        let response = AutoFillBrokerResponse.candidates(
            requestID: requestID,
            candidates: [candidate]
        )
        let decodedResponse = try AutoFillWire.decodeMessage(
            AutoFillBrokerResponse.self,
            from: AutoFillWire.encodeMessage(response)
        )
        guard case let .candidates(decodedResponseID, decodedCandidates) = decodedResponse else {
            Issue.record("Expected a candidate response")
            return
        }
        #expect(decodedResponseID == requestID)
        #expect(decodedCandidates == [candidate])
    }

    @Test("credential resolution remains a tagged version-two operation")
    func credentialResolutionRoundTrips() throws {
        let request = AutoFillBrokerRequest.resolveCredential(
            requestID: requestID,
            descriptorID: descriptorID,
            valueKind: .password,
            deadlineUptimeNanoseconds: 42_000_000_000,
            wakeHandle: wakeHandle
        )
        #expect(try roundTrip(request, as: AutoFillBrokerRequest.self) == request)
    }

    @Test("candidate responses round trip")
    func candidateResponsesRoundTrip() throws {
        let candidates = [
            AutoFillCandidate(
                descriptorID: descriptorID,
                title: "Example login",
                username: "person@example.com",
                kind: .password,
                matchTier: 0
            )
        ]
        let response = AutoFillBrokerResponse.candidates(requestID: requestID, candidates: candidates)
        #expect(try roundTrip(response, as: AutoFillBrokerResponse.self) == response)
    }

    @Test("query whitespace is normalized before encoding")
    func globalQueryWhitespaceIsNormalized() throws {
        let request = AutoFillBrokerRequest.listCandidates(.global(
            requestID: requestID,
            search: "  git\n  access  ",
            kind: .oneTimeCode,
            deadlineUptimeNanoseconds: 42_000_000_000
        ))
        let data = try AutoFillWire.encodeMessage(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["search"] as? String == "git access")
        let expected = AutoFillBrokerRequest.listCandidates(.global(
            requestID: requestID,
            search: "git access",
            kind: .oneTimeCode,
            deadlineUptimeNanoseconds: 42_000_000_000
        ))
        #expect(try AutoFillWire.decodeMessage(AutoFillBrokerRequest.self, from: data) == expected)
    }

    @Test("unknown operation and fields from another operation are rejected")
    func rejectsUnknownAndMixedOperations() throws {
        let unsupported: [String: Any] = [
            "version": AutoFillWire.protocolVersion,
            "messageKind": "request",
            "operation": "deleteCandidates",
            "requestID": requestID.uuidString
        ]
        #expect(throws: AutoFillProtocolError.unknownMessageKind) {
            try decodeRequest(unsupported)
        }

        let mixed: [String: Any] = [
            "version": AutoFillWire.protocolVersion,
            "messageKind": "request",
            "operation": "listCandidates",
            "queryKind": "global",
            "requestID": requestID.uuidString,
            "search": "git",
            "valueKind": "password",
            "deadlineUptimeNanoseconds": 99,
            "descriptorID": descriptorID.uuidString
        ]
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try decodeRequest(mixed)
        }
    }

    @Test("candidate protocol caps and invalid values are rejected")
    func rejectsInvalidCandidateInputs() throws {
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try AutoFillWire.encodeMessage(AutoFillBrokerRequest.listCandidates(.global(
                requestID: requestID, search: " \n ", kind: .password, deadlineUptimeNanoseconds: 99
            )))
        }
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try AutoFillWire.encodeMessage(AutoFillBrokerRequest.listCandidates(.global(
                requestID: requestID,
                search: String(repeating: "x", count: AutoFillCandidateQuery.maximumSearchQueryLength + 1),
                kind: .password,
                deadlineUptimeNanoseconds: 99
            )))
        }
        let validService: [String: Any] = [
            "kind": "domain",
            "identifier": "login.example.com"
        ]
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try decodeRequest(siteRequest(services: Array(
                repeating: validService,
                count: AutoFillCandidateQuery.maximumServiceIdentifiers + 1
            )))
        }
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            _ = try AutoFillServiceIdentifier(kind: .domain, identifier: "not a host", displayName: nil)
        }
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            _ = try AutoFillServiceIdentifier(kind: .url, identifier: "mailto:person@example.com", displayName: nil)
        }
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            _ = try AutoFillServiceIdentifier(kind: .app, identifier: "", displayName: nil)
        }

        let candidate: [String: Any] = [
            "descriptorID": descriptorID.uuidString,
            "title": "Example",
            "username": "person@example.com",
            "kind": "password",
            "matchTier": 0
        ]
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try AutoFillWire.decodeMessage(AutoFillBrokerResponse.self, from: JSONSerialization.data(withJSONObject: [
                "version": AutoFillWire.protocolVersion,
                "messageKind": "candidates",
                "requestID": requestID.uuidString,
                "candidates": Array(repeating: candidate, count: AutoFillCandidate.maximumCandidates + 1)
            ]))
        }
    }

    @Test("nested payload keys and non-app association intents are rejected")
    func rejectsInvalidNestedPayloads() throws {
        var service: [String: Any] = [
            "kind": "domain",
            "identifier": "login.example.com"
        ]
        service["unexpected"] = true
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try decodeRequest(siteRequest(services: [service]))
        }

        var candidate: [String: Any] = [
            "descriptorID": descriptorID.uuidString,
            "title": "Example",
            "username": "person@example.com",
            "kind": "password",
            "matchTier": 0
        ]
        candidate["unexpected"] = true
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try AutoFillWire.decodeMessage(AutoFillBrokerResponse.self, from: JSONSerialization.data(withJSONObject: [
                "version": AutoFillWire.protocolVersion,
                "messageKind": "candidates",
                "requestID": requestID.uuidString,
                "candidates": [candidate]
            ]))
        }

        var intent: [String: Any] = [
            "service": ["kind": "app", "identifier": "com.example.App"]
        ]
        intent["unexpected"] = true
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try decodeRequest(resolveRequest(appAssociationIntent: intent))
        }

        let nonAppIntent: [String: Any] = [
            "service": ["kind": "domain", "identifier": "login.example.com"]
        ]
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try decodeRequest(resolveRequest(appAssociationIntent: nonAppIntent))
        }
    }

    @Test("frame length and message-size caps remain enforced")
    func retainsWireBounds() throws {
        for length in [UInt32(0), UInt32(AutoFillWire.maximumMessageSize + 1)] {
            let pair = try SocketPair()
            defer { pair.close() }
            try pair.writeHeader(length)
            #expect(throws: AutoFillProtocolError.invalidLength) {
                let _: AutoFillBrokerRequest = try AutoFillWire.readMessage(
                    AutoFillBrokerRequest.self,
                    fromFileDescriptor: pair.reader
                )
            }
        }

        let response = AutoFillBrokerResponse.credential(
            requestID: requestID,
            value: String(repeating: "x", count: AutoFillWire.maximumMessageSize)
        )
        let pair = try SocketPair()
        defer { pair.close() }
        #expect(throws: AutoFillProtocolError.messageTooLarge) {
            try AutoFillWire.writeMessage(response, toFileDescriptor: pair.writer)
        }
    }

    @Test("version one, unknown fields, and response request ID mismatches are rejected")
    func rejectsInvalidPayloads() throws {
        let versionOne: [String: Any] = [
            "version": 1,
            "messageKind": "request",
            "operation": "listCandidates",
            "queryKind": "global",
            "requestID": requestID.uuidString,
            "search": "git",
            "valueKind": "password",
            "deadlineUptimeNanoseconds": 99
        ]
        #expect(throws: AutoFillProtocolError.unsupportedVersion) {
            try decodeRequest(versionOne)
        }

        var unknownField = versionOne
        unknownField["version"] = AutoFillWire.protocolVersion
        unknownField["unknown"] = true
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try decodeRequest(unknownField)
        }

        let response: [String: Any] = [
            "version": AutoFillWire.protocolVersion,
            "messageKind": "candidates",
            "requestID": UUID().uuidString,
            "candidates": []
        ]
        #expect(throws: AutoFillProtocolError.malformedMessage) {
            try AutoFillWire.decodeResponse(
                AutoFillBrokerResponse.self,
                from: JSONSerialization.data(withJSONObject: response),
                matching: requestID
            )
        }
    }

    private func roundTrip<T: AutoFillWireMessage & Equatable>(_ value: T, as type: T.Type) throws -> T {
        let pair = try SocketPair()
        defer { pair.close() }
        try AutoFillWire.writeMessage(value, toFileDescriptor: pair.writer)
        return try AutoFillWire.readMessage(type, fromFileDescriptor: pair.reader)
    }

    private func siteRequest(services: [[String: Any]]) -> [String: Any] {
        [
            "version": AutoFillWire.protocolVersion,
            "messageKind": "request",
            "operation": "listCandidates",
            "queryKind": "site",
            "requestID": requestID.uuidString,
            "services": services,
            "valueKind": "password",
            "deadlineUptimeNanoseconds": 99
        ]
    }

    private func resolveRequest(appAssociationIntent: [String: Any]) -> [String: Any] {
        [
            "version": AutoFillWire.protocolVersion,
            "messageKind": "request",
            "operation": "resolveCredential",
            "requestID": requestID.uuidString,
            "descriptorID": descriptorID.uuidString,
            "valueKind": "password",
            "deadlineUptimeNanoseconds": 99,
            "appAssociationIntent": appAssociationIntent
        ]
    }

    private func decodeRequest(_ object: [String: Any]) throws -> AutoFillBrokerRequest {
        try AutoFillWire.decodeMessage(
            AutoFillBrokerRequest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}

private struct SocketPair {
    let reader: Int32
    let writer: Int32

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.ENOTSOCK)
        }
        reader = descriptors[0]
        writer = descriptors[1]
    }

    func writeHeader(_ value: UInt32) throws {
        var bytes = value.bigEndian
        let result = withUnsafeBytes(of: &bytes) { buffer in
            Darwin.write(writer, buffer.baseAddress, buffer.count)
        }
        guard result == MemoryLayout<UInt32>.size else { throw POSIXError(.EIO) }
    }

    func close() {
        Darwin.close(reader)
        Darwin.close(writer)
    }
}
