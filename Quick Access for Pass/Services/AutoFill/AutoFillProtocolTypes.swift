import Foundation

nonisolated private struct AutoFillJSONKey: CodingKey, Sendable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

nonisolated private func requireExactJSONKeys(
    _ decoder: any Decoder,
    allowed: Set<String>
) throws {
    let container = try decoder.container(keyedBy: AutoFillJSONKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == allowed else {
        throw AutoFillProtocolError.malformedMessage
    }
}

nonisolated enum AutoFillProtocolError: Error, Equatable, Sendable {
    case connectionClosed
    case invalidLength
    case messageTooLarge
    case malformedMessage
    case unsupportedVersion
    case unknownMessageKind
    case unknownValueKind
}

nonisolated enum AutoFillValueKind: String, Sendable, Equatable, Codable {
    case password
    case oneTimeCode

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let kind = Self(rawValue: value) else {
            throw AutoFillProtocolError.unknownValueKind
        }
        self = kind
    }
}

nonisolated enum AutoFillServiceIdentifierKind: String, Codable, CaseIterable, Equatable, Sendable {
    case domain
    case url
    case app
}

nonisolated struct AutoFillServiceIdentifier: Codable, Equatable, Sendable {
    static let maximumAppIdentifierLength = 255

    let kind: AutoFillServiceIdentifierKind
    let identifier: String
    /// Presentation-only; never used as an association key.
    let displayName: String?

    init(kind: AutoFillServiceIdentifierKind, identifier: String, displayName: String?) throws {
        guard Self.isValid(identifier, for: kind) else {
            throw AutoFillProtocolError.malformedMessage
        }
        self.kind = kind
        self.identifier = identifier
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
        case displayName
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasDisplayName = container.contains(.displayName)
        try requireExactJSONKeys(
            decoder,
            allowed: hasDisplayName
                ? ["kind", "identifier", "displayName"]
                : ["kind", "identifier"]
        )
        try self.init(
            kind: container.decode(AutoFillServiceIdentifierKind.self, forKey: .kind),
            identifier: container.decode(String.self, forKey: .identifier),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName)
        )
    }

    func encode(to encoder: any Encoder) throws {
        guard Self.isValid(identifier, for: kind) else {
            throw AutoFillProtocolError.malformedMessage
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(identifier, forKey: .identifier)
        try container.encodeIfPresent(displayName, forKey: .displayName)
    }

    private static func isValid(_ identifier: String, for kind: AutoFillServiceIdentifierKind) -> Bool {
        switch kind {
        case .domain:
            return normalizedHost(fromDomain: identifier) != nil
        case .url:
            return normalizedHost(fromURL: identifier) != nil
        case .app:
            return identifier.isEmpty == false
                && identifier.count <= maximumAppIdentifierLength
                && identifier.unicodeScalars.allSatisfy { $0.properties.isWhitespace == false && $0.value >= 0x20 && $0.value != 0x7F }
        }
    }

    static func normalizedHost(for service: Self) -> String? {
        switch service.kind {
        case .domain:
            normalizedHost(fromDomain: service.identifier)
        case .url:
            normalizedHost(fromURL: service.identifier)
        case .app:
            nil
        }
    }

    private static func normalizedHost(fromDomain value: String) -> String? {
        guard value.isEmpty == false,
              value.unicodeScalars.allSatisfy({ $0.properties.isWhitespace == false }),
              value.contains("/") == false,
              value.contains("@") == false,
              let host = URLComponents(string: "https://\(value)")?.host,
              host.isEmpty == false else {
            return nil
        }
        return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func normalizedHost(fromURL value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme?.isEmpty == false,
              let host = components.host,
              host.isEmpty == false else {
            return nil
        }
        return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

nonisolated struct AutoFillCandidate: Codable, Equatable, Sendable {
    static let maximumCandidates = 20

    let descriptorID: UUID
    let title: String
    let username: String
    let kind: AutoFillValueKind
    /// Zero-based index into the supplied service identifiers; global search uses zero.
    let matchTier: Int

    private enum CodingKeys: String, CodingKey {
        case descriptorID
        case title
        case username
        case kind
        case matchTier
    }

    init(
        descriptorID: UUID,
        title: String,
        username: String,
        kind: AutoFillValueKind,
        matchTier: Int
    ) {
        self.descriptorID = descriptorID
        self.title = title
        self.username = username
        self.kind = kind
        self.matchTier = matchTier
    }

    init(from decoder: any Decoder) throws {
        try requireExactJSONKeys(
            decoder,
            allowed: ["descriptorID", "title", "username", "kind", "matchTier"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            descriptorID: try container.decode(UUID.self, forKey: .descriptorID),
            title: try container.decode(String.self, forKey: .title),
            username: try container.decode(String.self, forKey: .username),
            kind: try container.decode(AutoFillValueKind.self, forKey: .kind),
            matchTier: try container.decode(Int.self, forKey: .matchTier)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(descriptorID, forKey: .descriptorID)
        try container.encode(title, forKey: .title)
        try container.encode(username, forKey: .username)
        try container.encode(kind, forKey: .kind)
        try container.encode(matchTier, forKey: .matchTier)
    }
}

nonisolated enum AutoFillCandidateQuery: Equatable, Sendable {
    static let maximumSearchQueryLength = 128
    static let maximumServiceIdentifiers = 8

    case site(
        requestID: UUID,
        services: [AutoFillServiceIdentifier],
        kind: AutoFillValueKind,
        deadlineUptimeNanoseconds: UInt64,
        wakeHandle: UUID? = nil
    )
    case global(
        requestID: UUID,
        search: String,
        kind: AutoFillValueKind,
        deadlineUptimeNanoseconds: UInt64,
        wakeHandle: UUID? = nil
    )

    var requestID: UUID {
        switch self {
        case .site(let requestID, _, _, _, _), .global(let requestID, _, _, _, _): requestID
        }
    }

    var deadlineUptimeNanoseconds: UInt64 {
        switch self {
        case .site(_, _, _, let deadline, _), .global(_, _, _, let deadline, _): deadline
        }
    }

    var wakeHandle: UUID? {
        switch self {
        case .site(_, _, _, _, let wakeHandle), .global(_, _, _, _, let wakeHandle): wakeHandle
        }
    }

    private func validated() throws -> Self {
        switch self {
        case .site(_, let services, _, _, _):
            guard services.isEmpty == false, services.count <= Self.maximumServiceIdentifiers else {
                throw AutoFillProtocolError.malformedMessage
            }
        case .global(_, let search, _, _, _):
            guard Self.normalizedSearch(search) != nil else {
                throw AutoFillProtocolError.malformedMessage
            }
        }
        return self
    }

    static func normalizedSearch(_ search: String) -> String? {
        let normalized = search.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.isEmpty == false, normalized.count <= maximumSearchQueryLength else {
            return nil
        }
        return normalized
    }
}

nonisolated extension AutoFillCandidateQuery: Codable {
    private enum CodingKeys: String, CodingKey {
        case queryKind
        case requestID
        case services
        case search
        case valueKind
        case deadlineUptimeNanoseconds
        case wakeHandle
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(AutoFillValueKind.self, forKey: .valueKind)
        let requestID = try container.decode(UUID.self, forKey: .requestID)
        let deadline = try container.decode(UInt64.self, forKey: .deadlineUptimeNanoseconds)
        let wakeHandle = try container.decodeIfPresent(UUID.self, forKey: .wakeHandle)
        switch try container.decode(String.self, forKey: .queryKind) {
        case "site":
            let services = try container.decode(
                [AutoFillServiceIdentifier].self,
                forKey: .services
            )
            self = .site(
                requestID: requestID,
                services: services,
                kind: kind,
                deadlineUptimeNanoseconds: deadline,
                wakeHandle: wakeHandle
            )
        case "global":
            guard let search = Self.normalizedSearch(try container.decode(String.self, forKey: .search)) else {
                throw AutoFillProtocolError.malformedMessage
            }
            self = .global(requestID: requestID, search: search, kind: kind, deadlineUptimeNanoseconds: deadline, wakeHandle: wakeHandle)
        default:
            throw AutoFillProtocolError.unknownMessageKind
        }
        _ = try validated()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch try validated() {
        case .site(let requestID, let services, let kind, let deadline, let wakeHandle):
            try container.encode("site", forKey: .queryKind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(services, forKey: .services)
            try container.encode(kind, forKey: .valueKind)
            try container.encode(deadline, forKey: .deadlineUptimeNanoseconds)
            try container.encodeIfPresent(wakeHandle, forKey: .wakeHandle)
        case .global(let requestID, let search, let kind, let deadline, let wakeHandle):
            guard let normalized = Self.normalizedSearch(search) else { throw AutoFillProtocolError.malformedMessage }
            try container.encode("global", forKey: .queryKind)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(normalized, forKey: .search)
            try container.encode(kind, forKey: .valueKind)
            try container.encode(deadline, forKey: .deadlineUptimeNanoseconds)
            try container.encodeIfPresent(wakeHandle, forKey: .wakeHandle)
        }
    }
}

nonisolated struct AutoFillAppAssociationIntent: Codable, Equatable, Sendable {
    let service: AutoFillServiceIdentifier

    private enum CodingKeys: String, CodingKey {
        case service
    }

    init(service: AutoFillServiceIdentifier) throws {
        guard service.kind == .app else { throw AutoFillProtocolError.malformedMessage }
        self.service = service
    }

    init(from decoder: any Decoder) throws {
        try requireExactJSONKeys(decoder, allowed: ["service"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(service: container.decode(AutoFillServiceIdentifier.self, forKey: .service))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(service, forKey: .service)
    }
}
