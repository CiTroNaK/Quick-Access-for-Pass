import Foundation

nonisolated enum AutoFillBrokerFailure: String, Codable, Equatable, Sendable {
    case invalidRequest, unauthorized, expired, cancelled, unavailable, resolutionFailed
}

nonisolated enum AutoFillBrokerResponse: AutoFillWireMessage, Equatable, Sendable {
    case credential(requestID: UUID, value: String)
    case candidates(requestID: UUID, candidates: [AutoFillCandidate])
    case failure(requestID: UUID, failure: AutoFillBrokerFailure)

    static let allowedJSONKeys: Set<String> = ["version", "messageKind", "requestID", "value", "candidates", "failure"]

    private enum CodingKeys: String, CodingKey {
        case version
        case messageKind
        case requestID
        case value
        case candidates
        case failure
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(UInt16.self, forKey: .version) == AutoFillWire.protocolVersion else {
            throw AutoFillProtocolError.unsupportedVersion
        }
        let requestID = try container.decode(UUID.self, forKey: .requestID)
        switch try container.decode(String.self, forKey: .messageKind) {
        case "credential":
            self = .credential(
                requestID: requestID,
                value: try container.decode(String.self, forKey: .value)
            )
        case "candidates":
            let candidates = try container.decode([AutoFillCandidate].self, forKey: .candidates)
            guard candidates.count <= AutoFillCandidate.maximumCandidates else {
                throw AutoFillProtocolError.malformedMessage
            }
            self = .candidates(requestID: requestID, candidates: candidates)
        case "failure":
            self = .failure(
                requestID: requestID,
                failure: try container.decode(AutoFillBrokerFailure.self, forKey: .failure)
            )
        default:
            throw AutoFillProtocolError.unknownMessageKind
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(AutoFillWire.protocolVersion, forKey: .version)
        switch self {
        case .credential(let requestID, let value):
            try container.encode("credential", forKey: .messageKind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(value, forKey: .value)
        case .candidates(let requestID, let candidates):
            guard candidates.count <= AutoFillCandidate.maximumCandidates else {
                throw AutoFillProtocolError.malformedMessage
            }
            try container.encode("candidates", forKey: .messageKind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(candidates, forKey: .candidates)
        case .failure(let requestID, let failure):
            try container.encode("failure", forKey: .messageKind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(failure, forKey: .failure)
        }
    }

    static func validateJSONKeys(_ keys: Set<String>, in object: [String: Any]) -> Bool {
        switch object["messageKind"] as? String {
        case "credential": return keys == ["version", "messageKind", "requestID", "value"]
        case "candidates": return keys == ["version", "messageKind", "requestID", "candidates"]
        case "failure": return keys == ["version", "messageKind", "requestID", "failure"]
        default: return true
        }
    }

    var requestID: UUID {
        switch self {
        case .credential(let requestID, _), .candidates(let requestID, _), .failure(let requestID, _): requestID
        }
    }
}
