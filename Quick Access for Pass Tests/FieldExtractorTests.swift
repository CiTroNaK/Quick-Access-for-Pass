import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("FieldExtractor")
struct FieldExtractorTests {

    private func decode(_ json: String) throws -> CLIItem {
        try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
    }

    @Test("extracts credit card CVV")
    func cardCVV() throws {
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"CreditCard":{"cardholder_name":"","card_type":"","number":"",
             "verification_number":"<<FAKE_CVV>>","expiration_date":"","pin":""}},
           "extra_fields":[]}}
        """
        let item = try decode(json)
        #expect(FieldExtractor.value(for: .cardCVV, in: item) == "<<FAKE_CVV>>")
    }

    @Test("extracts login email")
    func loginEmail() throws {
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Login":{"email":"alice@example.com","username":"alice",
             "password":"<<FAKE_PASSWORD>>","urls":[],"totp_uri":"","passkeys":[]}},
           "extra_fields":[]}}
        """
        let item = try decode(json)
        #expect(FieldExtractor.value(for: .email, in: item) == "alice@example.com")
    }

    @Test("extracts extra field by name (text, hidden, totp)")
    func extraField() throws {
        let extras = """
        [
          {"name":"Memo","content":{"Text":"<<FAKE_MEMO>>"}},
          {"name":"Seed","content":{"Hidden":"<<FAKE_SEED>>"}},
          {"name":"T",   "content":{"Totp":"<<FAKE_TOTP_URI>>"}}
        ]
        """
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Note": null},
           "extra_fields":\(extras)}}
        """
        let item = try decode(json)
        #expect(FieldExtractor.value(for: .extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false), in: item) == "<<FAKE_MEMO>>")
        #expect(FieldExtractor.value(for: .extra(path: .topLevel(fieldIndex: 1), name: "Seed", isSensitive: true), in: item) == "<<FAKE_SEED>>")
        #expect(FieldExtractor.value(for: .extra(path: .topLevel(fieldIndex: 2), name: "T", isSensitive: true), in: item) == "<<FAKE_TOTP_URI>>")
    }

    @Test("extracts extra field from a custom item's section")
    func customSectionField() throws {
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Custom":{"sections":[
             {"section_name":"Bank","section_fields":[
                {"name":"Account","content":{"Text":"<<FAKE_ACCT>>"}}
             ]}
           ]}},
           "extra_fields":[]}}
        """
        let item = try decode(json)
        #expect(FieldExtractor.value(for: .extra(path: .customSection(sectionIndex: 0, fieldIndex: 0), name: "Account", isSensitive: false), in: item) == "<<FAKE_ACCT>>")
    }

    @Test("returns nil when FieldKey doesn't match item type")
    func mismatchReturnsNil() throws {
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Note": null},
           "extra_fields":[]}}
        """
        let item = try decode(json)
        #expect(FieldExtractor.value(for: .cardCVV, in: item) == nil)
    }

    @Test("extracts duplicate visible names by exact path")
    func duplicateVisibleNamesByPath() throws {
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Custom":{"sections":[
             {"section_name":"Bank A","section_fields":[
                {"name":"Code","content":{"Text":"111"}}
             ]},
             {"section_name":"Bank B","section_fields":[
                {"name":"Code","content":{"Text":"222"}}
             ]}
           ]}},
           "extra_fields":[]}}
        """
        let item = try decode(json)
        #expect(
            FieldExtractor.value(
                for: .extra(path: .customSection(sectionIndex: 0, fieldIndex: 0), name: "Code", isSensitive: false),
                in: item
            ) == "111"
        )
        #expect(
            FieldExtractor.value(
                for: .extra(path: .customSection(sectionIndex: 1, fieldIndex: 0), name: "Code", isSensitive: false),
                in: item
            ) == "222"
        )
    }

    @Test("returns nil for an empty field value (stale cache)")
    func emptyValueReturnsNil() throws {
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"CreditCard":{"cardholder_name":"","card_type":"","number":"",
             "verification_number":"","expiration_date":"","pin":""}},
           "extra_fields":[]}}
        """
        let item = try decode(json)
        #expect(FieldExtractor.value(for: .cardCVV, in: item) == nil)
    }

    /// The identity extractor has 30+ near-identical switch arms; a single
    /// copy-paste bug (e.g. `.identityFirstName` returning `.middleName`) would
    /// slip past an arm-per-type test. This parameterized test fills exactly
    /// one identity field with a case-specific sentinel and verifies the
    /// extractor returns that exact sentinel, for every built-in identity key.
    @Test("every built-in identity FieldKey extracts its own field",
          arguments: Self.allIdentityKeys)
    func identityExhaustive(key: FieldKey) throws {
        let sentinel = "<<SENTINEL_\(key.stableIdentifier)>>"
        let item = try singleFieldIdentity(key: key, value: sentinel)
        #expect(FieldExtractor.value(for: key, in: item) == sentinel)
    }

    private static let allIdentityKeys: [FieldKey] = [
        .identityFullName, .identityFirstName, .identityMiddleName, .identityLastName,
        .identityPhoneNumber, .identityBirthdate, .identityGender, .identityOrganization,
        .identityStreetAddress, .identityZipOrPostalCode, .identityCity, .identityStateOrProvince,
        .identityCountryOrRegion, .identityFloor, .identityCounty,
        .identitySocialSecurityNumber, .identityPassportNumber, .identityLicenseNumber,
        .identityWebsite, .identityXHandle, .identitySecondPhoneNumber,
        .identityLinkedin, .identityReddit, .identityFacebook, .identityYahoo, .identityInstagram,
        .identityCompany, .identityJobTitle, .identityPersonalWebsite,
        .identityWorkPhoneNumber, .identityWorkEmail,
    ]

    /// Decode an Identity CLIItem populating exactly one field. The JSON key
    /// map matches `CLIIdentityContent.CodingKeys`.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func singleFieldIdentity(key: FieldKey, value: String) throws -> CLIItem {
        let jsonKey: String = {
            switch key {
            case .identityFullName: "full_name"
            case .identityFirstName: "first_name"
            case .identityMiddleName: "middle_name"
            case .identityLastName: "last_name"
            case .identityPhoneNumber: "phone_number"
            case .identityBirthdate: "birthdate"
            case .identityGender: "gender"
            case .identityOrganization: "organization"
            case .identityStreetAddress: "street_address"
            case .identityZipOrPostalCode: "zip_or_postal_code"
            case .identityCity: "city"
            case .identityStateOrProvince: "state_or_province"
            case .identityCountryOrRegion: "country_or_region"
            case .identityFloor: "floor"
            case .identityCounty: "county"
            case .identitySocialSecurityNumber: "social_security_number"
            case .identityPassportNumber: "passport_number"
            case .identityLicenseNumber: "license_number"
            case .identityWebsite: "website"
            case .identityXHandle: "x_handle"
            case .identitySecondPhoneNumber: "second_phone_number"
            case .identityLinkedin: "linkedin"
            case .identityReddit: "reddit"
            case .identityFacebook: "facebook"
            case .identityYahoo: "yahoo"
            case .identityInstagram: "instagram"
            case .identityCompany: "company"
            case .identityJobTitle: "job_title"
            case .identityPersonalWebsite: "personal_website"
            case .identityWorkPhoneNumber: "work_phone_number"
            case .identityWorkEmail: "work_email"
            default: "full_name"  // unreachable; parameterized source is constrained above
            }
        }()
        // Sentinel contains no quotes, so raw interpolation into JSON is safe.
        let json = """
        {"id":"i","share_id":"s","vault_id":"v","state":"Active","flags":[],
         "create_time":"2026-01-01T00:00:00Z","modify_time":"2026-01-01T00:00:00Z",
         "content":{"title":"","note":"","item_uuid":"u",
           "content":{"Identity":{"\(jsonKey)":"\(value)"}},
           "extra_fields":[]}}
        """
        return try JSONDecoder().decode(CLIItem.self, from: Data(json.utf8))
    }
}
