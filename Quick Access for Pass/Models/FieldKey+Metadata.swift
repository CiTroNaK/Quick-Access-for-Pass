import Foundation

nonisolated extension ExtraFieldPath {
    var stableIdentifier: String {
        switch self {
        case .topLevel(let fieldIndex):
            return "topLevel:\(fieldIndex)"
        case .customSection(let sectionIndex, let fieldIndex):
            return "customSection:\(sectionIndex):\(fieldIndex)"
        }
    }
}

nonisolated extension FieldKey {
    /// `true` for fields whose CLI value is a secret, password, TOTP seed,
    /// private key, or another identifier users would not want on-screen.
    /// Drives the bottom-group lock glyph and accessibility hint.
    ///
    /// Exhaustive by design — adding a new case to `FieldKey` is a compile
    /// error here until it has been explicitly classified. Do not replace
    /// with a `default:` arm; security-relevant classification must not
    /// silently regress.
    var isSensitive: Bool {
        switch self {
        case .cardCVV, .cardPIN, .sshPrivateKey,
             .identitySocialSecurityNumber, .identityPassportNumber, .identityLicenseNumber:
            return true
        case .email,
             .cardholderName, .cardType, .cardExpiration,
             .wifiSSID, .wifiSecurity,
             .noteBody,
             .identityFullName, .identityFirstName, .identityMiddleName, .identityLastName,
             .identityPhoneNumber, .identityBirthdate, .identityGender, .identityOrganization,
             .identityStreetAddress, .identityZipOrPostalCode, .identityCity,
             .identityStateOrProvince, .identityCountryOrRegion, .identityFloor, .identityCounty,
             .identityWebsite, .identityXHandle, .identitySecondPhoneNumber,
             .identityLinkedin, .identityReddit, .identityFacebook, .identityYahoo, .identityInstagram,
             .identityCompany, .identityJobTitle, .identityPersonalWebsite,
             .identityWorkPhoneNumber, .identityWorkEmail:
            return false
        case .extra(_, _, let isSensitive):
            return isSensitive
        case .sectionHeader:
            return false
        }
    }

    /// Localized display label for built-in cases; user-provided `name`
    /// verbatim for `.extra` / `.sectionHeader`.
    var localizedLabel: String {
        switch self {
        case .email: String(localized: "Email")
        case .cardholderName: String(localized: "Cardholder Name")
        case .cardType: String(localized: "Card Type")
        case .cardExpiration: String(localized: "Expiration")
        case .cardCVV: String(localized: "CVV")
        case .cardPIN: String(localized: "PIN")
        case .sshPrivateKey: String(localized: "Private Key")
        case .wifiSSID: String(localized: "SSID")
        case .wifiSecurity: String(localized: "Security")
        case .noteBody: String(localized: "Note")
        case .identityFullName: String(localized: "Full Name")
        case .identityFirstName: String(localized: "First Name")
        case .identityMiddleName: String(localized: "Middle Name")
        case .identityLastName: String(localized: "Last Name")
        case .identityPhoneNumber: String(localized: "Phone Number")
        case .identityBirthdate: String(localized: "Birthdate")
        case .identityGender: String(localized: "Gender")
        case .identityOrganization: String(localized: "Organization")
        case .identityStreetAddress: String(localized: "Street Address")
        case .identityZipOrPostalCode: String(localized: "Zip / Postal Code")
        case .identityCity: String(localized: "City")
        case .identityStateOrProvince: String(localized: "State / Province")
        case .identityCountryOrRegion: String(localized: "Country / Region")
        case .identityFloor: String(localized: "Floor")
        case .identityCounty: String(localized: "County")
        case .identitySocialSecurityNumber: String(localized: "Social Security Number")
        case .identityPassportNumber: String(localized: "Passport Number")
        case .identityLicenseNumber: String(localized: "License Number")
        case .identityWebsite: String(localized: "Website")
        case .identityXHandle: String(localized: "X Handle")
        case .identitySecondPhoneNumber: String(localized: "Second Phone Number")
        case .identityLinkedin: String(localized: "LinkedIn")
        case .identityReddit: String(localized: "Reddit")
        case .identityFacebook: String(localized: "Facebook")
        case .identityYahoo: String(localized: "Yahoo")
        case .identityInstagram: String(localized: "Instagram")
        case .identityCompany: String(localized: "Company")
        case .identityJobTitle: String(localized: "Job Title")
        case .identityPersonalWebsite: String(localized: "Personal Website")
        case .identityWorkPhoneNumber: String(localized: "Work Phone Number")
        case .identityWorkEmail: String(localized: "Work Email")
        case .extra(_, let name, _): name
        case .sectionHeader(let name): name
        }
    }

    /// Compile-time-stable identifier for this key, used as a SwiftUI
    /// `Identifiable` component inside `DetailRow`. Mirrors the `Codable`
    /// tag discriminators so that on-disk and in-memory identity share the
    /// same shape, without depending on Mirror reflection over enum cases.
    ///
    /// Do not interpolate from `String(describing:)` or `"\(self)"` for
    /// this purpose — those use runtime reflection, which silently changes
    /// if an associated value is added to a case.
    var stableIdentifier: String {
        switch self {
        case .email: "email"
        case .cardholderName: "cardholderName"
        case .cardType: "cardType"
        case .cardExpiration: "cardExpiration"
        case .cardCVV: "cardCVV"
        case .cardPIN: "cardPIN"
        case .sshPrivateKey: "sshPrivateKey"
        case .wifiSSID: "wifiSSID"
        case .wifiSecurity: "wifiSecurity"
        case .noteBody: "noteBody"
        case .identityFullName: "identityFullName"
        case .identityFirstName: "identityFirstName"
        case .identityMiddleName: "identityMiddleName"
        case .identityLastName: "identityLastName"
        case .identityPhoneNumber: "identityPhoneNumber"
        case .identityBirthdate: "identityBirthdate"
        case .identityGender: "identityGender"
        case .identityOrganization: "identityOrganization"
        case .identityStreetAddress: "identityStreetAddress"
        case .identityZipOrPostalCode: "identityZipOrPostalCode"
        case .identityCity: "identityCity"
        case .identityStateOrProvince: "identityStateOrProvince"
        case .identityCountryOrRegion: "identityCountryOrRegion"
        case .identityFloor: "identityFloor"
        case .identityCounty: "identityCounty"
        case .identitySocialSecurityNumber: "identitySocialSecurityNumber"
        case .identityPassportNumber: "identityPassportNumber"
        case .identityLicenseNumber: "identityLicenseNumber"
        case .identityWebsite: "identityWebsite"
        case .identityXHandle: "identityXHandle"
        case .identitySecondPhoneNumber: "identitySecondPhoneNumber"
        case .identityLinkedin: "identityLinkedin"
        case .identityReddit: "identityReddit"
        case .identityFacebook: "identityFacebook"
        case .identityYahoo: "identityYahoo"
        case .identityInstagram: "identityInstagram"
        case .identityCompany: "identityCompany"
        case .identityJobTitle: "identityJobTitle"
        case .identityPersonalWebsite: "identityPersonalWebsite"
        case .identityWorkPhoneNumber: "identityWorkPhoneNumber"
        case .identityWorkEmail: "identityWorkEmail"
        case .extra(let path, let name, _): "extra:\(path.stableIdentifier):\(name)"
        case .sectionHeader(let name): "sectionHeader:\(name)"
        }
    }
}
