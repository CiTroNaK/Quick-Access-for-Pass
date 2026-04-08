import Foundation

/// Computes the ordered list of bottom-group `FieldKey`s for an item, using
/// only `!isEmpty` as the predicate over field values. Values are never
/// returned, logged, or retained — this is an information-preserving
/// *presence* computation, safe to persist.
///
/// Callers: `PassItem.init(from:vaultId:)` during sync (Task 5), and
/// `DetailRowBuilderTests` for unit coverage.
nonisolated enum DetailRowBuilder {

    static func fieldKeys(for cliItem: CLIItem) -> [FieldKey] {
        var keys: [FieldKey] = []
        keys.append(contentsOf: typeSpecificKeys(for: cliItem))
        keys.append(contentsOf: extraFieldKeys(cliItem.content.extraFields))
        keys.append(contentsOf: customSectionKeys(cliItem.content.content))
        return keys
    }

    // MARK: - Type-specific built-ins (dedup with top group applied)

    private static func typeSpecificKeys(for cliItem: CLIItem) -> [FieldKey] {
        switch cliItem.content.content {
        case .login(let login):
            return loginKeys(login: login, note: cliItem.content.note)
        case .creditCard(let card):
            return cardKeys(card: card)
        case .identity(let identity):
            return identityKeys(identity: identity, note: cliItem.content.note)
        case .sshKey(let ssh):
            return sshKeys(ssh: ssh, note: cliItem.content.note)
        case .wifi(let wifi):
            return wifiKeys(wifi: wifi, note: cliItem.content.note)
        case .note, .custom:
            // Note body is the top-group primary for these types.
            return []
        case .alias:
            return []
        }
    }

    private static func loginKeys(login: CLILoginContent, note: String) -> [FieldKey] {
        // `PassItem.init(from:vaultId:)` derives the header subtitle as
        // `username.isEmpty ? email : username`. Skip the bottom-group
        // `.email` row whenever it would duplicate whatever is already in
        // the header, so a login with only an email doesn't render twice.
        let topShownEmail = login.username.isEmpty ? login.email : login.username
        var out: [FieldKey] = []
        if !login.email.isEmpty && login.email != topShownEmail {
            out.append(.email)
        }
        if !note.isEmpty {
            out.append(.noteBody)
        }
        return out
    }

    private static func cardKeys(card: CLICreditCardContent) -> [FieldKey] {
        var out: [FieldKey] = []
        if !card.cardholderName.isEmpty { out.append(.cardholderName) }
        if !card.cardType.isEmpty { out.append(.cardType) }
        if !card.expirationDate.isEmpty { out.append(.cardExpiration) }
        if !card.verificationNumber.isEmpty { out.append(.cardCVV) }
        if !card.pin.isEmpty { out.append(.cardPIN) }
        return out
    }

    private static func sshKeys(ssh: CLISshKeyContent, note: String) -> [FieldKey] {
        var out: [FieldKey] = []
        if !ssh.privateKey.isEmpty { out.append(.sshPrivateKey) }
        if !note.isEmpty { out.append(.noteBody) }
        return out
    }

    private static func wifiKeys(wifi: CLIWifiContent, note: String) -> [FieldKey] {
        var out: [FieldKey] = []
        if !wifi.ssid.isEmpty { out.append(.wifiSSID) }
        if !wifi.security.isEmpty { out.append(.wifiSecurity) }
        if !note.isEmpty { out.append(.noteBody) }
        return out
    }

    // Walks every identity field in declared order. The long straight-line
    // body and branch count are intrinsic to the shape of CLIIdentityContent.
    // swiftlint:disable:next cyclomatic_complexity
    private static func identityKeys(identity: CLIIdentityContent, note: String) -> [FieldKey] {
        // Walk the fields in the same order as `CLIIdentityContent` declares them.
        //
        // Note: `identity.email` is deliberately excluded here. For identity items,
        // the top-group primary action is `.copyPrimary` → `identity.email`
        // (see `QuickAccessViewModel.copyPrimarySecret`). Emitting `.email` in the
        // bottom group would duplicate that action, so we skip it here the same
        // way `wifiKeys` skips `wifi.password` (top-group primary) and
        // `sshKeys` skips `ssh.publicKey` (top-group primary).
        var out: [FieldKey] = []
        if !identity.fullName.isEmpty { out.append(.identityFullName) }
        if !identity.phoneNumber.isEmpty { out.append(.identityPhoneNumber) }
        if !identity.firstName.isEmpty { out.append(.identityFirstName) }
        if !identity.middleName.isEmpty { out.append(.identityMiddleName) }
        if !identity.lastName.isEmpty { out.append(.identityLastName) }
        if !identity.birthdate.isEmpty { out.append(.identityBirthdate) }
        if !identity.gender.isEmpty { out.append(.identityGender) }
        if !identity.organization.isEmpty { out.append(.identityOrganization) }
        if !identity.streetAddress.isEmpty { out.append(.identityStreetAddress) }
        if !identity.zipOrPostalCode.isEmpty { out.append(.identityZipOrPostalCode) }
        if !identity.city.isEmpty { out.append(.identityCity) }
        if !identity.stateOrProvince.isEmpty { out.append(.identityStateOrProvince) }
        if !identity.countryOrRegion.isEmpty { out.append(.identityCountryOrRegion) }
        if !identity.floor.isEmpty { out.append(.identityFloor) }
        if !identity.county.isEmpty { out.append(.identityCounty) }
        if !identity.socialSecurityNumber.isEmpty { out.append(.identitySocialSecurityNumber) }
        if !identity.passportNumber.isEmpty { out.append(.identityPassportNumber) }
        if !identity.licenseNumber.isEmpty { out.append(.identityLicenseNumber) }
        if !identity.website.isEmpty { out.append(.identityWebsite) }
        if !identity.xHandle.isEmpty { out.append(.identityXHandle) }
        if !identity.secondPhoneNumber.isEmpty { out.append(.identitySecondPhoneNumber) }
        if !identity.linkedin.isEmpty { out.append(.identityLinkedin) }
        if !identity.reddit.isEmpty { out.append(.identityReddit) }
        if !identity.facebook.isEmpty { out.append(.identityFacebook) }
        if !identity.yahoo.isEmpty { out.append(.identityYahoo) }
        if !identity.instagram.isEmpty { out.append(.identityInstagram) }
        if !identity.company.isEmpty { out.append(.identityCompany) }
        if !identity.jobTitle.isEmpty { out.append(.identityJobTitle) }
        if !identity.personalWebsite.isEmpty { out.append(.identityPersonalWebsite) }
        if !identity.workPhoneNumber.isEmpty { out.append(.identityWorkPhoneNumber) }
        if !identity.workEmail.isEmpty { out.append(.identityWorkEmail) }
        if !note.isEmpty { out.append(.noteBody) }
        return out
    }

    // MARK: - Extra fields (flat list, sensitivity inferred from CLI tag)

    private static func extraFieldKeys(_ extras: [CLIExtraField]) -> [FieldKey] {
        extras.enumerated().compactMap { index, extra in
            let value: String
            let isSensitive: Bool
            switch extra.content {
            case .text(let fieldValue):
                value = fieldValue
                isSensitive = false
            case .hidden(let fieldValue):
                value = fieldValue
                isSensitive = true
            case .totp(let fieldValue):
                value = fieldValue
                isSensitive = true
            }
            return value.isEmpty ? nil : .extra(
                path: .topLevel(fieldIndex: index),
                name: extra.name,
                isSensitive: isSensitive
            )
        }
    }

    // MARK: - Custom-item sections

    private static func customSectionKeys(_ content: CLIItemTypeContent) -> [FieldKey] {
        guard case .custom(let custom) = content else { return [] }
        var out: [FieldKey] = []
        for (sectionIndex, section) in custom.sections.enumerated() {
            let sectionFieldKeys = section.sectionFields.enumerated().compactMap { fieldIndex, extra -> FieldKey? in
                let value: String
                let isSensitive: Bool
                switch extra.content {
                case .text(let fieldValue):
                    value = fieldValue
                    isSensitive = false
                case .hidden(let fieldValue):
                    value = fieldValue
                    isSensitive = true
                case .totp(let fieldValue):
                    value = fieldValue
                    isSensitive = true
                }
                guard !value.isEmpty else { return nil }
                return .extra(
                    path: .customSection(sectionIndex: sectionIndex, fieldIndex: fieldIndex),
                    name: extra.name,
                    isSensitive: isSensitive
                )
            }
            if sectionFieldKeys.isEmpty { continue }
            out.append(.sectionHeader(name: section.sectionName))
            out.append(contentsOf: sectionFieldKeys)
        }
        return out
    }
}
