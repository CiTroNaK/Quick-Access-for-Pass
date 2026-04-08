import Foundation

/// Closed identifier for every type-specific built-in field that can appear in
/// the item-detail bottom group, plus open cases for user-defined custom data.
///
/// Sensitive-field values are *never* rendered in the UI; this type only names
/// fields so the row list and field extractor can agree on what to copy.
nonisolated enum ExtraFieldPath: Sendable, Hashable, Codable {
    case topLevel(fieldIndex: Int)
    case customSection(sectionIndex: Int, fieldIndex: Int)
}

nonisolated enum FieldKey: Sendable, Hashable {
    // Login
    case email

    // Credit card — Card Number is top-group only, no case here.
    case cardholderName
    case cardType
    case cardExpiration
    case cardCVV
    case cardPIN

    // SSH key — Public Key is always the top-group primary and has no FieldKey case.
    case sshPrivateKey

    // Wi-Fi — password is top-group only, no case here.
    case wifiSSID
    case wifiSecurity

    // Note body — for non-note, non-custom items that happen to carry a non-empty
    // CLIItemContent.note (for note and custom items it is the top-group primary).
    case noteBody

    // Identity — Email is the top-group primary and has no FieldKey case.
    case identityFullName
    case identityFirstName
    case identityMiddleName
    case identityLastName
    case identityPhoneNumber
    case identityBirthdate
    case identityGender
    case identityOrganization
    case identityStreetAddress
    case identityZipOrPostalCode
    case identityCity
    case identityStateOrProvince
    case identityCountryOrRegion
    case identityFloor
    case identityCounty
    case identitySocialSecurityNumber
    case identityPassportNumber
    case identityLicenseNumber
    case identityWebsite
    case identityXHandle
    case identitySecondPhoneNumber
    case identityLinkedin
    case identityReddit
    case identityFacebook
    case identityYahoo
    case identityInstagram
    case identityCompany
    case identityJobTitle
    case identityPersonalWebsite
    case identityWorkPhoneNumber
    case identityWorkEmail

    // Open cases for user-provided field names.
    //
    // The associated `name` participates in `Hashable` / `Equatable` and
    // therefore in the persisted `stableIdentifier`. That is deliberate: a
    // row's identity is (path, name) together, so renaming a field upstream
    // invalidates the persisted entry until the next sync rewrites
    // `items.fieldKeysJSON`. The ordered `path` remains the authoritative
    // lookup key for value extraction in `FieldExtractor`.
    //
    // `isSensitive` mirrors the `CLIExtraFieldContent` tag: `true` for
    // `.hidden` and `.totp`, `false` for `.text`. It drives the lock-glyph
    // rendering in the detail view.
    case extra(path: ExtraFieldPath, name: String, isSensitive: Bool)
    case sectionHeader(name: String)
}
