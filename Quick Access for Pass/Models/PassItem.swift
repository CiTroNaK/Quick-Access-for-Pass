import Foundation
import GRDB
import os

nonisolated struct PassItem: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    let id: String
    let vaultId: String
    let title: String
    let itemType: ItemType
    let subtitle: String
    let url: String?
    let hasTOTP: Bool
    let state: String
    let createTime: Date
    let modifyTime: Date

    var useCount: Int
    var lastUsedAt: Date?

    /// Ordered list of bottom-group field identifiers (built-in type-specific +
    /// custom/extra) that were non-empty the last time the item was synced from
    /// `pass-cli`. Stored in the `fieldKeysJSON` TEXT column as a JSON
    /// array. Never contains secret *values* — only field *presence*.
    var fieldKeys: [FieldKey]

    static let databaseTableName = "items"

    // GRDB uses the Codable representation. Map `fieldKeys` to a TEXT
    // column holding its JSON-encoded form.
    enum CodingKeys: String, CodingKey {
        case id, vaultId, title, itemType, subtitle, url, hasTOTP, state
        case createTime, modifyTime, useCount, lastUsedAt
        case fieldKeys = "fieldKeysJSON"
    }

    init(
        id: String, vaultId: String, title: String, itemType: ItemType,
        subtitle: String, url: String?, hasTOTP: Bool, state: String,
        createTime: Date, modifyTime: Date,
        useCount: Int, lastUsedAt: Date?,
        fieldKeys: [FieldKey] = []
    ) {
        self.id = id
        self.vaultId = vaultId
        self.title = title
        self.itemType = itemType
        self.subtitle = subtitle
        self.url = url
        self.hasTOTP = hasTOTP
        self.state = state
        self.createTime = createTime
        self.modifyTime = modifyTime
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.fieldKeys = fieldKeys
    }

    // GRDB <-> JSON-string column for fieldKeys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.vaultId = try container.decode(String.self, forKey: .vaultId)
        self.title = try container.decode(String.self, forKey: .title)
        self.itemType = try container.decode(ItemType.self, forKey: .itemType)
        self.subtitle = try container.decode(String.self, forKey: .subtitle)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.hasTOTP = try container.decode(Bool.self, forKey: .hasTOTP)
        self.state = try container.decode(String.self, forKey: .state)
        self.createTime = try container.decode(Date.self, forKey: .createTime)
        self.modifyTime = try container.decode(Date.self, forKey: .modifyTime)
        self.useCount = try container.decode(Int.self, forKey: .useCount)
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)

        let itemID = self.id
        let json = try container.decodeIfPresent(String.self, forKey: .fieldKeys) ?? "[]"
        do {
            self.fieldKeys = try JSONDecoder().decode([FieldKey].self, from: Data(json.utf8))
        } catch {
            AppLogger.database.error(
                "fieldKeysJSON decode failed for item \(itemID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            self.fieldKeys = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(vaultId, forKey: .vaultId)
        try container.encode(title, forKey: .title)
        try container.encode(itemType, forKey: .itemType)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(hasTOTP, forKey: .hasTOTP)
        try container.encode(state, forKey: .state)
        try container.encode(createTime, forKey: .createTime)
        try container.encode(modifyTime, forKey: .modifyTime)
        try container.encode(useCount, forKey: .useCount)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)

        let data: Data
        do {
            data = try JSONEncoder().encode(fieldKeys)
        } catch {
            AppLogger.database.error(
                "fieldKeysJSON encode failed for item \(self.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            data = Data("[]".utf8)
        }
        let json = String(data: data, encoding: .utf8) ?? "[]"
        try container.encode(json, forKey: .fieldKeys)
    }
}

extension PassItem {
    /// Create from CLI response. Extracts only non-sensitive fields for caching,
    /// plus the bottom-group field *presence* list (computed via DetailRowBuilder
    /// — no secret values leave this initializer).
    init(from cliItem: CLIItem, vaultId: String) {
        let bottom = DetailRowBuilder.fieldKeys(for: cliItem)

        let content = cliItem.content.content
        let derivedSubtitle: String
        let derivedURL: String?
        let derivedHasTOTP: Bool
        switch content {
        case .login(let login):
            derivedSubtitle = login.username.isEmpty ? login.email : login.username
            derivedURL = login.urls.first
            derivedHasTOTP = !login.totpUri.isEmpty
        case .creditCard(let card):
            derivedSubtitle = card.cardholderName
            derivedURL = nil
            derivedHasTOTP = false
        case .identity(let identity):
            derivedSubtitle = identity.email
            derivedURL = nil
            derivedHasTOTP = false
        case .wifi(let wifi):
            derivedSubtitle = wifi.ssid
            derivedURL = nil
            derivedHasTOTP = false
        case .alias, .sshKey, .note, .custom:
            derivedSubtitle = ""
            derivedURL = nil
            derivedHasTOTP = false
        }

        self.init(
            id: cliItem.id,
            vaultId: vaultId,
            title: cliItem.content.title,
            itemType: content.itemType,
            subtitle: derivedSubtitle,
            url: derivedURL,
            hasTOTP: derivedHasTOTP,
            state: cliItem.state,
            createTime: Self.parseDate(cliItem.createTime),
            modifyTime: Self.parseDate(cliItem.modifyTime),
            useCount: 0,
            lastUsedAt: nil,
            fieldKeys: bottom
        )
    }

    /// Parse an ISO 8601 date string, trying the fractional-seconds format
    /// first and falling back to the plain format. Returns `Date()` on
    /// total parse failure.
    ///
    /// Constructs formatters per-call intentionally: `DateFormatter` (the
    /// parent class of `ISO8601DateFormatter`) is explicitly not
    /// thread-safe, and Apple does not document `ISO8601DateFormatter`
    /// as thread-safe either. `ISO8601DateFormatter.init()` is
    /// microseconds, and this method is called at most twice per
    /// `PassItem` import during sync (a one-shot operation, not a hot
    /// path), so the allocation cost is immeasurable.
    private static func parseDate(_ string: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string) ?? Date()
    }
}
