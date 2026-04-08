import Foundation

nonisolated extension ExtraFieldPath {
    private enum CodingKeys: String, CodingKey {
        case kind
        case sectionIndex
        case fieldIndex
    }

    private enum Kind: String, Codable {
        case topLevel
        case customSection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .topLevel:
            self = .topLevel(fieldIndex: try container.decode(Int.self, forKey: .fieldIndex))
        case .customSection:
            self = .customSection(
                sectionIndex: try container.decode(Int.self, forKey: .sectionIndex),
                fieldIndex: try container.decode(Int.self, forKey: .fieldIndex)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .topLevel(let fieldIndex):
            try container.encode(Kind.topLevel, forKey: .kind)
            try container.encode(fieldIndex, forKey: .fieldIndex)
        case .customSection(let sectionIndex, let fieldIndex):
            try container.encode(Kind.customSection, forKey: .kind)
            try container.encode(sectionIndex, forKey: .sectionIndex)
            try container.encode(fieldIndex, forKey: .fieldIndex)
        }
    }
}

// MARK: - Codable (tagged representation)

nonisolated extension FieldKey: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case path
        case name
        case isSensitive
    }

    /// Stable discriminators. Do not rename — they are persisted in the
    /// `items.fieldKeysJSON` column.
    private enum Tag: String, Codable {
        case email
        case cardholderName, cardType, cardExpiration, cardCVV, cardPIN
        case sshPrivateKey
        case wifiSSID, wifiSecurity
        case noteBody
        case identityFullName, identityFirstName, identityMiddleName, identityLastName
        case identityPhoneNumber, identityBirthdate, identityGender, identityOrganization
        case identityStreetAddress, identityZipOrPostalCode, identityCity, identityStateOrProvince
        case identityCountryOrRegion, identityFloor, identityCounty
        case identitySocialSecurityNumber, identityPassportNumber, identityLicenseNumber
        case identityWebsite, identityXHandle, identitySecondPhoneNumber
        case identityLinkedin, identityReddit, identityFacebook, identityYahoo, identityInstagram
        case identityCompany, identityJobTitle, identityPersonalWebsite
        case identityWorkPhoneNumber, identityWorkEmail
        case extra
        case sectionHeader
    }

    // The exhaustive switch mirrors on-disk stable tags; keep explicit.
    // swiftlint:disable:next cyclomatic_complexity
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(Tag.self, forKey: .tag)
        switch tag {
        case .email: self = .email
        case .cardholderName: self = .cardholderName
        case .cardType: self = .cardType
        case .cardExpiration: self = .cardExpiration
        case .cardCVV: self = .cardCVV
        case .cardPIN: self = .cardPIN
        case .sshPrivateKey: self = .sshPrivateKey
        case .wifiSSID: self = .wifiSSID
        case .wifiSecurity: self = .wifiSecurity
        case .noteBody: self = .noteBody
        case .identityFullName: self = .identityFullName
        case .identityFirstName: self = .identityFirstName
        case .identityMiddleName: self = .identityMiddleName
        case .identityLastName: self = .identityLastName
        case .identityPhoneNumber: self = .identityPhoneNumber
        case .identityBirthdate: self = .identityBirthdate
        case .identityGender: self = .identityGender
        case .identityOrganization: self = .identityOrganization
        case .identityStreetAddress: self = .identityStreetAddress
        case .identityZipOrPostalCode: self = .identityZipOrPostalCode
        case .identityCity: self = .identityCity
        case .identityStateOrProvince: self = .identityStateOrProvince
        case .identityCountryOrRegion: self = .identityCountryOrRegion
        case .identityFloor: self = .identityFloor
        case .identityCounty: self = .identityCounty
        case .identitySocialSecurityNumber: self = .identitySocialSecurityNumber
        case .identityPassportNumber: self = .identityPassportNumber
        case .identityLicenseNumber: self = .identityLicenseNumber
        case .identityWebsite: self = .identityWebsite
        case .identityXHandle: self = .identityXHandle
        case .identitySecondPhoneNumber: self = .identitySecondPhoneNumber
        case .identityLinkedin: self = .identityLinkedin
        case .identityReddit: self = .identityReddit
        case .identityFacebook: self = .identityFacebook
        case .identityYahoo: self = .identityYahoo
        case .identityInstagram: self = .identityInstagram
        case .identityCompany: self = .identityCompany
        case .identityJobTitle: self = .identityJobTitle
        case .identityPersonalWebsite: self = .identityPersonalWebsite
        case .identityWorkPhoneNumber: self = .identityWorkPhoneNumber
        case .identityWorkEmail: self = .identityWorkEmail
        case .extra:
            let path = try container.decode(ExtraFieldPath.self, forKey: .path)
            let name = try container.decode(String.self, forKey: .name)
            let sensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
            self = .extra(path: path, name: name, isSensitive: sensitive)
        case .sectionHeader:
            let name = try container.decode(String.self, forKey: .name)
            self = .sectionHeader(name: name)
        }
    }

    // The exhaustive switch mirrors on-disk stable tags; keep explicit.
    // swiftlint:disable:next cyclomatic_complexity
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .email: try container.encode(Tag.email, forKey: .tag)
        case .cardholderName: try container.encode(Tag.cardholderName, forKey: .tag)
        case .cardType: try container.encode(Tag.cardType, forKey: .tag)
        case .cardExpiration: try container.encode(Tag.cardExpiration, forKey: .tag)
        case .cardCVV: try container.encode(Tag.cardCVV, forKey: .tag)
        case .cardPIN: try container.encode(Tag.cardPIN, forKey: .tag)
        case .sshPrivateKey: try container.encode(Tag.sshPrivateKey, forKey: .tag)
        case .wifiSSID: try container.encode(Tag.wifiSSID, forKey: .tag)
        case .wifiSecurity: try container.encode(Tag.wifiSecurity, forKey: .tag)
        case .noteBody: try container.encode(Tag.noteBody, forKey: .tag)
        case .identityFullName: try container.encode(Tag.identityFullName, forKey: .tag)
        case .identityFirstName: try container.encode(Tag.identityFirstName, forKey: .tag)
        case .identityMiddleName: try container.encode(Tag.identityMiddleName, forKey: .tag)
        case .identityLastName: try container.encode(Tag.identityLastName, forKey: .tag)
        case .identityPhoneNumber: try container.encode(Tag.identityPhoneNumber, forKey: .tag)
        case .identityBirthdate: try container.encode(Tag.identityBirthdate, forKey: .tag)
        case .identityGender: try container.encode(Tag.identityGender, forKey: .tag)
        case .identityOrganization: try container.encode(Tag.identityOrganization, forKey: .tag)
        case .identityStreetAddress: try container.encode(Tag.identityStreetAddress, forKey: .tag)
        case .identityZipOrPostalCode: try container.encode(Tag.identityZipOrPostalCode, forKey: .tag)
        case .identityCity: try container.encode(Tag.identityCity, forKey: .tag)
        case .identityStateOrProvince: try container.encode(Tag.identityStateOrProvince, forKey: .tag)
        case .identityCountryOrRegion: try container.encode(Tag.identityCountryOrRegion, forKey: .tag)
        case .identityFloor: try container.encode(Tag.identityFloor, forKey: .tag)
        case .identityCounty: try container.encode(Tag.identityCounty, forKey: .tag)
        case .identitySocialSecurityNumber: try container.encode(Tag.identitySocialSecurityNumber, forKey: .tag)
        case .identityPassportNumber: try container.encode(Tag.identityPassportNumber, forKey: .tag)
        case .identityLicenseNumber: try container.encode(Tag.identityLicenseNumber, forKey: .tag)
        case .identityWebsite: try container.encode(Tag.identityWebsite, forKey: .tag)
        case .identityXHandle: try container.encode(Tag.identityXHandle, forKey: .tag)
        case .identitySecondPhoneNumber: try container.encode(Tag.identitySecondPhoneNumber, forKey: .tag)
        case .identityLinkedin: try container.encode(Tag.identityLinkedin, forKey: .tag)
        case .identityReddit: try container.encode(Tag.identityReddit, forKey: .tag)
        case .identityFacebook: try container.encode(Tag.identityFacebook, forKey: .tag)
        case .identityYahoo: try container.encode(Tag.identityYahoo, forKey: .tag)
        case .identityInstagram: try container.encode(Tag.identityInstagram, forKey: .tag)
        case .identityCompany: try container.encode(Tag.identityCompany, forKey: .tag)
        case .identityJobTitle: try container.encode(Tag.identityJobTitle, forKey: .tag)
        case .identityPersonalWebsite: try container.encode(Tag.identityPersonalWebsite, forKey: .tag)
        case .identityWorkPhoneNumber: try container.encode(Tag.identityWorkPhoneNumber, forKey: .tag)
        case .identityWorkEmail: try container.encode(Tag.identityWorkEmail, forKey: .tag)
        case .extra(let path, let name, let isSensitive):
            try container.encode(Tag.extra, forKey: .tag)
            try container.encode(path, forKey: .path)
            try container.encode(name, forKey: .name)
            try container.encode(isSensitive, forKey: .isSensitive)
        case .sectionHeader(let name):
            try container.encode(Tag.sectionHeader, forKey: .tag)
            try container.encode(name, forKey: .name)
        }
    }
}
