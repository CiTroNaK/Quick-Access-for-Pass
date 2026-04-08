// swiftlint:disable file_length
import Foundation

// MARK: - Vault List Response

nonisolated struct CLIVaultListResponse: Codable, Sendable {
    let vaults: [CLIVault]
}

nonisolated struct CLIVault: Codable, Sendable {
    let name: String
    let vaultId: String
    let shareId: String

    enum CodingKeys: String, CodingKey {
        case name
        case vaultId = "vault_id"
        case shareId = "share_id"
    }
}

// MARK: - Item List Response

nonisolated struct CLIItemListResponse: Codable, Sendable {
    let items: [CLIItem]
}

nonisolated struct CLIItem: Codable, Sendable {
    let id: String
    let shareId: String
    let vaultId: String
    let content: CLIItemContent
    let state: String
    let flags: [String]
    let createTime: String
    let modifyTime: String

    enum CodingKeys: String, CodingKey {
        case id
        case shareId = "share_id"
        case vaultId = "vault_id"
        case content, state, flags
        case createTime = "create_time"
        case modifyTime = "modify_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        shareId = try container.decode(String.self, forKey: .shareId)
        vaultId = try container.decode(String.self, forKey: .vaultId)
        content = try container.decode(CLIItemContent.self, forKey: .content)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "Active"
        flags = try container.decodeIfPresent([String].self, forKey: .flags) ?? []
        createTime = try container.decodeIfPresent(String.self, forKey: .createTime) ?? ""
        modifyTime = try container.decodeIfPresent(String.self, forKey: .modifyTime) ?? ""
    }
}

nonisolated struct CLIItemContent: Codable, Sendable {
    let title: String
    let note: String
    let itemUuid: String
    let content: CLIItemTypeContent
    let extraFields: [CLIExtraField]

    enum CodingKeys: String, CodingKey {
        case title, note, content
        case itemUuid = "item_uuid"
        case extraFields = "extra_fields"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        itemUuid = try container.decodeIfPresent(String.self, forKey: .itemUuid) ?? ""
        content = try container.decode(CLIItemTypeContent.self, forKey: .content)
        extraFields = try container.decodeIfPresent([CLIExtraField].self, forKey: .extraFields) ?? []
    }
}

nonisolated struct CLIExtraField: Codable, Sendable {
    let name: String
    let content: CLIExtraFieldContent
}

nonisolated enum CLIExtraFieldContent: Codable, Sendable {
    case text(String)
    case hidden(String)
    case totp(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        if let key = container.allKeys.first {
            let value = try container.decode(String.self, forKey: key)
            switch key.stringValue {
            case "Text": self = .text(value)
            case "Hidden": self = .hidden(value)
            case "Totp": self = .totp(value)
            default: self = .text(value)
            }
        } else {
            self = .text("")
        }
    }

    // short decoder container vars
    // swiftlint:disable identifier_name
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        switch self {
        case .text(let v): try container.encode(v, forKey: DynamicCodingKey(stringValue: "Text")!)
        case .hidden(let v): try container.encode(v, forKey: DynamicCodingKey(stringValue: "Hidden")!)
        case .totp(let v): try container.encode(v, forKey: DynamicCodingKey(stringValue: "Totp")!)
        }
    }
    // swiftlint:enable identifier_name
}

// MARK: - Tagged Enum for Item Type Content

nonisolated enum CLIItemTypeContent: Codable, Sendable {
    case login(CLILoginContent)
    case note
    case alias
    case creditCard(CLICreditCardContent)
    case identity(CLIIdentityContent)
    case sshKey(CLISshKeyContent)
    case wifi(CLIWifiContent)
    case custom(CLICustomContent)

    // CodingKey cases match pass-cli JSON keys
    // swiftlint:disable identifier_name
    private enum TypeKey: String, CodingKey {
        case Login, Note, Alias, CreditCard, Identity, SshKey, Wifi, Custom
    }
    // swiftlint:enable identifier_name

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)

        if container.contains(.Login) {
            self = .login(try container.decode(CLILoginContent.self, forKey: .Login))
        } else if container.contains(.Note) {
            self = .note
        } else if container.contains(.Alias) {
            self = .alias
        } else if container.contains(.CreditCard) {
            self = .creditCard(try container.decode(CLICreditCardContent.self, forKey: .CreditCard))
        } else if container.contains(.Identity) {
            self = .identity(try container.decode(CLIIdentityContent.self, forKey: .Identity))
        } else if container.contains(.SshKey) {
            self = .sshKey(try container.decode(CLISshKeyContent.self, forKey: .SshKey))
        } else if container.contains(.Wifi) {
            self = .wifi(try container.decode(CLIWifiContent.self, forKey: .Wifi))
        } else if container.contains(.Custom) {
            self = .custom(try container.decode(CLICustomContent.self, forKey: .Custom))
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown item type")
            )
        }
    }

    // short decoder container vars
    // swiftlint:disable identifier_name
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .login(let v): try container.encode(v, forKey: .Login)
        case .note: try container.encodeNil(forKey: .Note)
        case .alias: try container.encodeNil(forKey: .Alias)
        case .creditCard(let v): try container.encode(v, forKey: .CreditCard)
        case .identity(let v): try container.encode(v, forKey: .Identity)
        case .sshKey(let v): try container.encode(v, forKey: .SshKey)
        case .wifi(let v): try container.encode(v, forKey: .Wifi)
        case .custom(let v): try container.encode(v, forKey: .Custom)
        }
    }
    // swiftlint:enable identifier_name

    var itemType: ItemType {
        switch self {
        case .login: .login
        case .note: .note
        case .alias: .alias
        case .creditCard: .creditCard
        case .identity: .identity
        case .sshKey: .sshKey
        case .wifi: .wifi
        case .custom: .custom
        }
    }
}

nonisolated struct CLILoginContent: Sendable {
    let email: String
    let username: String
    let password: String
    let urls: [String]
    let totpUri: String
    let passkeys: [CLIPasskey]

    enum CodingKeys: String, CodingKey {
        case email, username, password, urls, passkeys
        case totpUri = "totp_uri"
    }
}

extension CLILoginContent: Codable {
    init(from decoder: Decoder) throws {
        // short decoder container var
        // swiftlint:disable:next identifier_name
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
        totpUri = try c.decodeIfPresent(String.self, forKey: .totpUri) ?? ""
        passkeys = try c.decodeIfPresent([CLIPasskey].self, forKey: .passkeys) ?? []
    }
}

nonisolated struct CLIPasskey: Codable, Sendable {
    let keyId: String
    let domain: String
    let rpId: String
    let rpName: String
    let userName: String
    let userDisplayName: String

    enum CodingKeys: String, CodingKey {
        case domain
        case keyId = "key_id"
        case rpId = "rp_id"
        case rpName = "rp_name"
        case userName = "user_name"
        case userDisplayName = "user_display_name"
    }
}

nonisolated struct CLICreditCardContent: Codable, Sendable {
    let cardholderName: String
    let cardType: String
    let number: String
    let verificationNumber: String
    let expirationDate: String
    let pin: String

    enum CodingKeys: String, CodingKey {
        case number, pin
        case cardholderName = "cardholder_name"
        case cardType = "card_type"
        case verificationNumber = "verification_number"
        case expirationDate = "expiration_date"
    }
}

nonisolated struct CLIIdentityContent: Sendable {
    let fullName: String
    let email: String
    let phoneNumber: String
    let firstName: String
    let middleName: String
    let lastName: String
    let birthdate: String
    let gender: String
    let organization: String
    let streetAddress: String
    let zipOrPostalCode: String
    let city: String
    let stateOrProvince: String
    let countryOrRegion: String
    let floor: String
    let county: String
    let socialSecurityNumber: String
    let passportNumber: String
    let licenseNumber: String
    let website: String
    let xHandle: String
    let secondPhoneNumber: String
    let linkedin: String
    let reddit: String
    let facebook: String
    let yahoo: String
    let instagram: String
    let company: String
    let jobTitle: String
    let personalWebsite: String
    let workPhoneNumber: String
    let workEmail: String

    enum CodingKeys: String, CodingKey {
        case email, organization, city, floor, county, website, linkedin, reddit, facebook, yahoo, instagram, company, gender, birthdate
        case fullName = "full_name"
        case phoneNumber = "phone_number"
        case firstName = "first_name"
        case middleName = "middle_name"
        case lastName = "last_name"
        case streetAddress = "street_address"
        case zipOrPostalCode = "zip_or_postal_code"
        case stateOrProvince = "state_or_province"
        case countryOrRegion = "country_or_region"
        case socialSecurityNumber = "social_security_number"
        case passportNumber = "passport_number"
        case licenseNumber = "license_number"
        case xHandle = "x_handle"
        case secondPhoneNumber = "second_phone_number"
        case jobTitle = "job_title"
        case personalWebsite = "personal_website"
        case workPhoneNumber = "work_phone_number"
        case workEmail = "work_email"
    }
}

extension CLIIdentityContent: Codable {
    init(from decoder: Decoder) throws {
        // short decoder container var
        // swiftlint:disable:next identifier_name
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        phoneNumber = try c.decodeIfPresent(String.self, forKey: .phoneNumber) ?? ""
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName) ?? ""
        middleName = try c.decodeIfPresent(String.self, forKey: .middleName) ?? ""
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName) ?? ""
        birthdate = try c.decodeIfPresent(String.self, forKey: .birthdate) ?? ""
        gender = try c.decodeIfPresent(String.self, forKey: .gender) ?? ""
        organization = try c.decodeIfPresent(String.self, forKey: .organization) ?? ""
        streetAddress = try c.decodeIfPresent(String.self, forKey: .streetAddress) ?? ""
        zipOrPostalCode = try c.decodeIfPresent(String.self, forKey: .zipOrPostalCode) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        stateOrProvince = try c.decodeIfPresent(String.self, forKey: .stateOrProvince) ?? ""
        countryOrRegion = try c.decodeIfPresent(String.self, forKey: .countryOrRegion) ?? ""
        floor = try c.decodeIfPresent(String.self, forKey: .floor) ?? ""
        county = try c.decodeIfPresent(String.self, forKey: .county) ?? ""
        socialSecurityNumber = try c.decodeIfPresent(String.self, forKey: .socialSecurityNumber) ?? ""
        passportNumber = try c.decodeIfPresent(String.self, forKey: .passportNumber) ?? ""
        licenseNumber = try c.decodeIfPresent(String.self, forKey: .licenseNumber) ?? ""
        website = try c.decodeIfPresent(String.self, forKey: .website) ?? ""
        xHandle = try c.decodeIfPresent(String.self, forKey: .xHandle) ?? ""
        secondPhoneNumber = try c.decodeIfPresent(String.self, forKey: .secondPhoneNumber) ?? ""
        linkedin = try c.decodeIfPresent(String.self, forKey: .linkedin) ?? ""
        reddit = try c.decodeIfPresent(String.self, forKey: .reddit) ?? ""
        facebook = try c.decodeIfPresent(String.self, forKey: .facebook) ?? ""
        yahoo = try c.decodeIfPresent(String.self, forKey: .yahoo) ?? ""
        instagram = try c.decodeIfPresent(String.self, forKey: .instagram) ?? ""
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? ""
        jobTitle = try c.decodeIfPresent(String.self, forKey: .jobTitle) ?? ""
        personalWebsite = try c.decodeIfPresent(String.self, forKey: .personalWebsite) ?? ""
        workPhoneNumber = try c.decodeIfPresent(String.self, forKey: .workPhoneNumber) ?? ""
        workEmail = try c.decodeIfPresent(String.self, forKey: .workEmail) ?? ""
    }
}

nonisolated struct CLISshKeyContent: Codable, Sendable {
    let privateKey: String
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case privateKey = "private_key"
        case publicKey = "public_key"
    }
}

nonisolated struct CLIWifiContent: Codable, Sendable {
    let ssid: String
    let password: String
    let security: String
}

nonisolated struct CLICustomContent: Codable, Sendable {
    let sections: [CLICustomSection]
}

nonisolated struct CLICustomSection: Codable, Sendable {
    let sectionName: String
    let sectionFields: [CLIExtraField]

    enum CodingKeys: String, CodingKey {
        case sectionName = "section_name"
        case sectionFields = "section_fields"
    }
}

// MARK: - TOTP Response

nonisolated struct CLITotpResponse: Codable, Sendable {
    let totpUri: String
    let totp: String

    enum CodingKeys: String, CodingKey {
        case totpUri = "totp_uri"
        case totp
    }
}

// MARK: - Item View Response

nonisolated struct CLIItemViewResponse: Codable, Sendable {
    let item: CLIItem
}

// MARK: - Dynamic Coding Key

nonisolated struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}
