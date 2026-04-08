import Foundation

/// Extracts one field value from a fully-decoded `CLIItem`. Exhaustive over
/// every `FieldKey` case; returns `nil` when the key doesn't match the item
/// type or the field is unexpectedly empty (stale cache).
///
/// The returned `String` contains a secret. Callers must hand it directly
/// to `ClipboardManager.copy(_:)` and let it drop out of scope. Never bind
/// to a stored property, log, or interpolate into user-visible strings.
///
/// Field *names* (the associated value of `.extra(path:name:isSensitive:)`) may
/// be spoken by VoiceOver via the copy toast and rendered in the detail
/// view row list — the invariant is that names are hint-level metadata,
/// while values are secrets that never leave this function other than
/// through the single `clipboardManager.copy(...)` call at the sole
/// caller in `QuickAccessViewModel.copyField(_:from:)`.
nonisolated enum FieldExtractor {

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func value(for key: FieldKey, in cliItem: CLIItem) -> String? {
        let content = cliItem.content.content
        switch key {
        case .email:
            if case .login(let login) = content, !login.email.isEmpty { return login.email }
            return nil
        case .cardholderName:
            if case .creditCard(let card) = content, !card.cardholderName.isEmpty { return card.cardholderName }
            return nil
        case .cardType:
            if case .creditCard(let card) = content, !card.cardType.isEmpty { return card.cardType }
            return nil
        case .cardExpiration:
            if case .creditCard(let card) = content, !card.expirationDate.isEmpty { return card.expirationDate }
            return nil
        case .cardCVV:
            if case .creditCard(let card) = content, !card.verificationNumber.isEmpty { return card.verificationNumber }
            return nil
        case .cardPIN:
            if case .creditCard(let card) = content, !card.pin.isEmpty { return card.pin }
            return nil
        case .sshPrivateKey:
            if case .sshKey(let ssh) = content, !ssh.privateKey.isEmpty { return ssh.privateKey }
            return nil
        case .wifiSSID:
            if case .wifi(let wifi) = content, !wifi.ssid.isEmpty { return wifi.ssid }
            return nil
        case .wifiSecurity:
            if case .wifi(let wifi) = content, !wifi.security.isEmpty { return wifi.security }
            return nil
        case .noteBody:
            return cliItem.content.note.isEmpty ? nil : cliItem.content.note
        case .identityFullName: return identityValue(content) { $0.fullName }
        case .identityFirstName: return identityValue(content) { $0.firstName }
        case .identityMiddleName: return identityValue(content) { $0.middleName }
        case .identityLastName: return identityValue(content) { $0.lastName }
        case .identityPhoneNumber: return identityValue(content) { $0.phoneNumber }
        case .identityBirthdate: return identityValue(content) { $0.birthdate }
        case .identityGender: return identityValue(content) { $0.gender }
        case .identityOrganization: return identityValue(content) { $0.organization }
        case .identityStreetAddress: return identityValue(content) { $0.streetAddress }
        case .identityZipOrPostalCode: return identityValue(content) { $0.zipOrPostalCode }
        case .identityCity: return identityValue(content) { $0.city }
        case .identityStateOrProvince: return identityValue(content) { $0.stateOrProvince }
        case .identityCountryOrRegion: return identityValue(content) { $0.countryOrRegion }
        case .identityFloor: return identityValue(content) { $0.floor }
        case .identityCounty: return identityValue(content) { $0.county }
        case .identitySocialSecurityNumber: return identityValue(content) { $0.socialSecurityNumber }
        case .identityPassportNumber: return identityValue(content) { $0.passportNumber }
        case .identityLicenseNumber: return identityValue(content) { $0.licenseNumber }
        case .identityWebsite: return identityValue(content) { $0.website }
        case .identityXHandle: return identityValue(content) { $0.xHandle }
        case .identitySecondPhoneNumber: return identityValue(content) { $0.secondPhoneNumber }
        case .identityLinkedin: return identityValue(content) { $0.linkedin }
        case .identityReddit: return identityValue(content) { $0.reddit }
        case .identityFacebook: return identityValue(content) { $0.facebook }
        case .identityYahoo: return identityValue(content) { $0.yahoo }
        case .identityInstagram: return identityValue(content) { $0.instagram }
        case .identityCompany: return identityValue(content) { $0.company }
        case .identityJobTitle: return identityValue(content) { $0.jobTitle }
        case .identityPersonalWebsite: return identityValue(content) { $0.personalWebsite }
        case .identityWorkPhoneNumber: return identityValue(content) { $0.workPhoneNumber }
        case .identityWorkEmail: return identityValue(content) { $0.workEmail }
        case .extra(let path, _, _):
            return extraValue(at: path, in: cliItem)
        case .sectionHeader:
            // Not selectable; extractor is never called with this case.
            return nil
        }
    }

    // MARK: - Helpers

    private static func identityValue(
        _ content: CLIItemTypeContent,
        _ pick: (CLIIdentityContent) -> String
    ) -> String? {
        guard case .identity(let identity) = content else { return nil }
        let value = pick(identity)
        return value.isEmpty ? nil : value
    }

    private static func extraValue(at path: ExtraFieldPath, in cliItem: CLIItem) -> String? {
        switch path {
        case .topLevel(let fieldIndex):
            return valueAt(index: fieldIndex, in: cliItem.content.extraFields)
        case .customSection(let sectionIndex, let fieldIndex):
            guard case .custom(let custom) = cliItem.content.content,
                  custom.sections.indices.contains(sectionIndex) else {
                return nil
            }
            return valueAt(index: fieldIndex, in: custom.sections[sectionIndex].sectionFields)
        }
    }

    private static func valueAt(index: Int, in fields: [CLIExtraField]) -> String? {
        guard fields.indices.contains(index) else { return nil }
        let value: String
        switch fields[index].content {
        case .text(let fieldValue), .hidden(let fieldValue), .totp(let fieldValue):
            value = fieldValue
        }
        return value.isEmpty ? nil : value
    }
}
