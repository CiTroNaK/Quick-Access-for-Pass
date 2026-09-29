import Foundation

nonisolated protocol AutoFillWireMessage: Codable, Sendable {
    static var allowedJSONKeys: Set<String> { get }
    static func validateJSONKeys(_ keys: Set<String>, in object: [String: Any]) -> Bool
}

extension AutoFillWireMessage {
    static func validateJSONKeys(_ keys: Set<String>, in object: [String: Any]) -> Bool {
        keys.isSubset(of: allowedJSONKeys)
    }
}

nonisolated enum AutoFillBrokerRequest: AutoFillWireMessage, Equatable, Sendable {
    case resolveCredential(
        requestID: UUID,
        descriptorID: UUID,
        valueKind: AutoFillValueKind,
        deadlineUptimeNanoseconds: UInt64,
        wakeHandle: UUID? = nil,
        appAssociationIntent: AutoFillAppAssociationIntent? = nil
    )
    case listCandidates(AutoFillCandidateQuery)

    static let allowedJSONKeys: Set<String> = [
        "version", "messageKind", "operation", "requestID", "descriptorID", "valueKind",
        "deadlineUptimeNanoseconds", "wakeHandle", "appAssociationIntent", "queryKind", "services", "search"
    ]

    init(
        requestID: UUID,
        descriptorID: UUID,
        valueKind: AutoFillValueKind,
        deadlineUptimeNanoseconds: UInt64,
        wakeHandle: UUID? = nil
    ) {
        self = .resolveCredential(
            requestID: requestID,
            descriptorID: descriptorID,
            valueKind: valueKind,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            wakeHandle: wakeHandle
        )
    }

    var requestID: UUID {
        switch self {
        case .resolveCredential(let requestID, _, _, _, _, _): requestID
        case .listCandidates(let query): query.requestID
        }
    }

    var descriptorID: UUID {
        guard case .resolveCredential(_, let descriptorID, _, _, _, _) = self else { preconditionFailure("Candidate requests have no descriptor") }
        return descriptorID
    }

    var valueKind: AutoFillValueKind {
        switch self {
        case .resolveCredential(_, _, let valueKind, _, _, _): valueKind
        case .listCandidates(.site(_, _, let valueKind, _, _)), .listCandidates(.global(_, _, let valueKind, _, _)): valueKind
        }
    }

    var deadlineUptimeNanoseconds: UInt64 {
        switch self {
        case .resolveCredential(_, _, _, let deadline, _, _): deadline
        case .listCandidates(let query): query.deadlineUptimeNanoseconds
        }
    }

    var wakeHandle: UUID? {
        switch self {
        case .resolveCredential(_, _, _, _, let wakeHandle, _): wakeHandle
        case .listCandidates(let query): query.wakeHandle
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case messageKind
        case operation
        case requestID
        case descriptorID
        case valueKind
        case deadlineUptimeNanoseconds
        case wakeHandle
        case appAssociationIntent
        case queryKind
        case services
        case search
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(UInt16.self, forKey: .version) == AutoFillWire.protocolVersion else { throw AutoFillProtocolError.unsupportedVersion }
        guard try container.decode(String.self, forKey: .messageKind) == "request" else { throw AutoFillProtocolError.unknownMessageKind }
        let operation = try container.decode(String.self, forKey: .operation)
        guard operation == "resolveCredential" || operation == "listCandidates" else {
            throw AutoFillProtocolError.unknownMessageKind
        }
        let requestID = try container.decode(UUID.self, forKey: .requestID)
        let kind = try container.decode(AutoFillValueKind.self, forKey: .valueKind)
        let deadline = try container.decode(UInt64.self, forKey: .deadlineUptimeNanoseconds)
        let wakeHandle = try container.decodeIfPresent(UUID.self, forKey: .wakeHandle)
        switch operation {
        case "resolveCredential":
            let descriptorID = try container.decode(UUID.self, forKey: .descriptorID)
            let appAssociationIntent = try container.decodeIfPresent(
                AutoFillAppAssociationIntent.self,
                forKey: .appAssociationIntent
            )
            self = .resolveCredential(
                requestID: requestID,
                descriptorID: descriptorID,
                valueKind: kind,
                deadlineUptimeNanoseconds: deadline,
                wakeHandle: wakeHandle,
                appAssociationIntent: appAssociationIntent
            )
        case "listCandidates":
            self = .listCandidates(try AutoFillCandidateQuery(from: decoder))
        default:
            throw AutoFillProtocolError.unknownMessageKind
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(AutoFillWire.protocolVersion, forKey: .version)
        try container.encode("request", forKey: .messageKind)
        switch self {
        case .resolveCredential(let requestID, let descriptorID, let kind, let deadline, let wakeHandle, let intent):
            try container.encode("resolveCredential", forKey: .operation)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(descriptorID, forKey: .descriptorID)
            try container.encode(kind, forKey: .valueKind)
            try container.encode(deadline, forKey: .deadlineUptimeNanoseconds)
            try container.encodeIfPresent(wakeHandle, forKey: .wakeHandle)
            try container.encodeIfPresent(intent, forKey: .appAssociationIntent)
        case .listCandidates(let query):
            try container.encode("listCandidates", forKey: .operation)
            try query.encode(to: encoder)
        }
    }

    static func validateJSONKeys(_ keys: Set<String>, in object: [String: Any]) -> Bool {
        guard let operation = object["operation"] as? String else { return false }
        switch operation {
        case "resolveCredential":
            return keys == [
                "version", "messageKind", "operation", "requestID", "descriptorID",
                "valueKind", "deadlineUptimeNanoseconds"
            ] || keys == [
                "version", "messageKind", "operation", "requestID", "descriptorID",
                "valueKind", "deadlineUptimeNanoseconds", "wakeHandle"
            ] || keys == [
                "version", "messageKind", "operation", "requestID", "descriptorID",
                "valueKind", "deadlineUptimeNanoseconds", "appAssociationIntent"
            ] || keys == [
                "version", "messageKind", "operation", "requestID", "descriptorID",
                "valueKind", "deadlineUptimeNanoseconds", "wakeHandle", "appAssociationIntent"
            ]
        case "listCandidates":
            guard let queryKind = object["queryKind"] as? String else { return false }
            let base: Set<String> = ["version", "messageKind", "operation", "queryKind", "requestID", "valueKind", "deadlineUptimeNanoseconds"]
            let required = queryKind == "site" ? base.union(["services"]) : queryKind == "global" ? base.union(["search"]) : []
            return keys == required || keys == required.union(["wakeHandle"])
        default:
            return true
        }
    }
}
