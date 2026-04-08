import Testing
import Foundation
@testable import Quick_Access_for_Pass

// Sentinel strings throughout these tests are obvious-fake by design.
// They exist so the credential-leak assertion test (Task 9) can grep
// for them in logs and toast output.

@Suite("DetailRowBuilder")
struct DetailRowBuilderTests {

    private func decode(_ json: String) throws -> CLIItem {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(CLIItem.self, from: data)
    }

    private func loginJSON(
        email: String = "",
        username: String = "<<FAKE_USER>>",
        password: String = "<<FAKE_PASSWORD>>",
        urls: [String] = ["https://example.com"],
        totpUri: String = "",
        note: String = "",
        extraFields: String = "[]"
    ) -> String {
        let urlsJSON = urls.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "id": "id-1", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Example",
            "note": "\(note)",
            "item_uuid": "uuid-1",
            "content": { "Login": {
              "email": "\(email)",
              "username": "\(username)",
              "password": "\(password)",
              "urls": [\(urlsJSON)],
              "totp_uri": "\(totpUri)",
              "passkeys": []
            }},
            "extra_fields": \(extraFields)
          }
        }
        """
    }

    @Test("login with only username+password has empty bottom group")
    func loginEmptyBottom() throws {
        let item = try decode(loginJSON())
        #expect(DetailRowBuilder.fieldKeys(for: item).isEmpty)
    }

    @Test("login with distinct non-empty email emits .email")
    func loginWithEmail() throws {
        let item = try decode(loginJSON(email: "alice@example.com", username: "alice"))
        #expect(DetailRowBuilder.fieldKeys(for: item) == [.email])
    }

    @Test("login with non-empty note emits .noteBody after .email")
    func loginWithNote() throws {
        let item = try decode(loginJSON(email: "alice@example.com", note: "hint"))
        #expect(DetailRowBuilder.fieldKeys(for: item) == [.email, .noteBody])
    }

    @Test("login with email equal to username does not emit .email")
    func loginEmailEqualsUsername() throws {
        let item = try decode(loginJSON(email: "alice", username: "alice"))
        #expect(DetailRowBuilder.fieldKeys(for: item).isEmpty)
    }

    @Test("login with empty username + non-empty email does not emit .email")
    func loginOnlyEmailNoUsername() throws {
        // When username is empty, PassItem.init(from:vaultId:) uses the email
        // as the header subtitle. The bottom group must dedup against that so
        // the email doesn't appear twice.
        let item = try decode(loginJSON(email: "alice@example.com", username: ""))
        #expect(DetailRowBuilder.fieldKeys(for: item).isEmpty)
    }

    @Test("alias item has empty bottom group")
    func aliasEmptyBottom() throws {
        let json = """
        {
          "id": "id-8", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Alias", "note": "", "item_uuid": "uuid-8",
            "content": { "Alias": null },
            "extra_fields": []
          }
        }
        """
        let item = try decode(json)
        #expect(DetailRowBuilder.fieldKeys(for: item).isEmpty)
    }

    // MARK: - Credit card

    private func cardJSON(
        cardholder: String = "", type: String = "",
        number: String = "4111111111111111",
        cvv: String = "", expiration: String = "", pin: String = ""
    ) -> String {
        """
        {
          "id": "id-2", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Visa", "note": "", "item_uuid": "uuid-2",
            "content": { "CreditCard": {
              "cardholder_name": "\(cardholder)",
              "card_type": "\(type)",
              "number": "\(number)",
              "verification_number": "\(cvv)",
              "expiration_date": "\(expiration)",
              "pin": "\(pin)"
            }},
            "extra_fields": []
          }
        }
        """
    }

    @Test("credit card with all non-primary fields populated")
    func cardFullBottom() throws {
        let item = try decode(cardJSON(
            cardholder: "<<FAKE_NAME>>",
            type: "Visa",
            cvv: "<<FAKE_CVV>>",
            expiration: "12/30",
            pin: "<<FAKE_PIN>>"
        ))
        #expect(DetailRowBuilder.fieldKeys(for: item) == [
            .cardholderName, .cardType, .cardExpiration, .cardCVV, .cardPIN,
        ])
    }

    @Test("credit card with only number has empty bottom group")
    func cardNumberOnly() throws {
        let item = try decode(cardJSON())
        #expect(DetailRowBuilder.fieldKeys(for: item).isEmpty)
    }

    // MARK: - SSH key

    @Test("ssh key with private key emits .sshPrivateKey")
    func sshPrivate() throws {
        let json = """
        {
          "id": "id-3", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "SSH", "note": "", "item_uuid": "uuid-3",
            "content": { "SshKey": {
              "private_key": "<<FAKE_PRIVATE_KEY>>",
              "public_key": "ssh-ed25519 AAAA"
            }},
            "extra_fields": []
          }
        }
        """
        let item = try decode(json)
        #expect(DetailRowBuilder.fieldKeys(for: item) == [.sshPrivateKey])
    }

    // MARK: - Wi-Fi

    @Test("wifi with security emits .wifiSecurity")
    func wifiSecurity() throws {
        let json = """
        {
          "id": "id-4", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Home Wi-Fi", "note": "", "item_uuid": "uuid-4",
            "content": { "Wifi": {
              "ssid": "HomeNet",
              "password": "<<FAKE_WIFI_PASSWORD>>",
              "security": "WPA2"
            }},
            "extra_fields": []
          }
        }
        """
        let item = try decode(json)
        #expect(DetailRowBuilder.fieldKeys(for: item) == [.wifiSSID, .wifiSecurity])
    }

    @Test("wifi emits SSID before Security when both are non-empty")
    func wifiSSIDAndSecurity() throws {
        let json = """
        {
          "id": "id-9", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Home Wi-Fi", "note": "", "item_uuid": "uuid-9",
            "content": { "Wifi": {
              "ssid": "HomeNet",
              "password": "<<FAKE_WIFI_PASSWORD>>",
              "security": "WPA2"
            }},
            "extra_fields": []
          }
        }
        """
        let item = try decode(json)
        #expect(DetailRowBuilder.fieldKeys(for: item) == [.wifiSSID, .wifiSecurity])
    }

    // MARK: - Identity (subset)

    @Test("identity only emits non-empty fields in declared order")
    func identitySubset() throws {
        let json = """
        {
          "id": "id-5", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Me", "note": "", "item_uuid": "uuid-5",
            "content": { "Identity": {
              "full_name": "Alice Example",
              "email": "alice@example.com",
              "phone_number": "",
              "city": "Prague",
              "social_security_number": "<<FAKE_SSN>>"
            }},
            "extra_fields": []
          }
        }
        """
        let item = try decode(json)
        #expect(DetailRowBuilder.fieldKeys(for: item) == [
            .identityFullName, .identityCity, .identitySocialSecurityNumber,
        ])
    }

    // MARK: - Note (top-group only)

    @Test("note item has empty bottom group (note body is top-group primary)")
    func noteItemEmptyBottom() throws {
        let json = """
        {
          "id": "id-6", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Note", "note": "body", "item_uuid": "uuid-6",
            "content": { "Note": null },
            "extra_fields": []
          }
        }
        """
        let item = try decode(json)
        #expect(DetailRowBuilder.fieldKeys(for: item).isEmpty)
    }

    // MARK: - Extra fields

    @Test("extra fields ordering preserved; empty values dropped")
    func extraOrdering() throws {
        let extras = """
        [
          {"name": "Recovery Code", "content": {"Hidden": "<<FAKE_RECOVERY>>"}},
          {"name": "Empty",         "content": {"Text":   ""}},
          {"name": "Memo",          "content": {"Text":   "reminder"}}
        ]
        """
        let item = try decode(loginJSON(extraFields: extras))
        #expect(DetailRowBuilder.fieldKeys(for: item) == [
            .extra(path: .topLevel(fieldIndex: 0), name: "Recovery Code", isSensitive: true),
            .extra(path: .topLevel(fieldIndex: 2), name: "Memo", isSensitive: false),
        ])
    }

    // MARK: - Custom sections

    @Test("custom item emits section header then its non-empty fields")
    func customSections() throws {
        let json = """
        {
          "id": "id-7", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Custom", "note": "", "item_uuid": "uuid-7",
            "content": { "Custom": { "sections": [
              { "section_name": "Bank", "section_fields": [
                {"name": "Account", "content": {"Text": "123"}},
                {"name": "SWIFT",   "content": {"Text": ""}}
              ]},
              { "section_name": "Empty", "section_fields": [
                {"name": "Nothing", "content": {"Text": ""}}
              ]}
            ]}},
            "extra_fields": []
          }
        }
        """
        let item = try decode(json)
        #expect(DetailRowBuilder.fieldKeys(for: item) == [
            .sectionHeader(name: "Bank"),
            .extra(path: .customSection(sectionIndex: 0, fieldIndex: 0), name: "Account", isSensitive: false),
        ])
    }

    @Test("duplicate visible names get distinct exact paths")
    func duplicateVisibleNamesHaveDistinctPaths() throws {
        let json = """
        {
          "id": "id-10", "share_id": "s1", "vault_id": "v1",
          "state": "Active", "flags": [],
          "create_time": "2026-01-01T00:00:00Z",
          "modify_time": "2026-01-01T00:00:00Z",
          "content": {
            "title": "Custom", "note": "", "item_uuid": "uuid-10",
            "content": { "Custom": { "sections": [
              { "section_name": "Bank A", "section_fields": [
                {"name": "Code", "content": {"Text": "111"}}
              ]},
              { "section_name": "Bank B", "section_fields": [
                {"name": "Code", "content": {"Text": "222"}}
              ]}
            ]}},
            "extra_fields": []
          }
        }
        """
        let item = try decode(json)
        #expect(DetailRowBuilder.fieldKeys(for: item) == [
            .sectionHeader(name: "Bank A"),
            .extra(path: .customSection(sectionIndex: 0, fieldIndex: 0), name: "Code", isSensitive: false),
            .sectionHeader(name: "Bank B"),
            .extra(path: .customSection(sectionIndex: 1, fieldIndex: 0), name: "Code", isSensitive: false),
        ])
    }
}
