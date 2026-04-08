import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("ItemType Tests")
struct ItemTypeTests {
    @Test("raw values match pass-cli filter types")
    func rawValues() {
        #expect(ItemType.login.rawValue == "login")
        #expect(ItemType.creditCard.rawValue == "credit-card")
        #expect(ItemType.note.rawValue == "note")
        #expect(ItemType.identity.rawValue == "identity")
        #expect(ItemType.alias.rawValue == "alias")
        #expect(ItemType.sshKey.rawValue == "ssh-key")
        #expect(ItemType.wifi.rawValue == "wifi")
        #expect(ItemType.custom.rawValue == "custom")
    }

    @Test("displayName provides human-readable names")
    func displayNames() {
        #expect(ItemType.login.displayName == "Login")
        #expect(ItemType.creditCard.displayName == "Credit Card")
        #expect(ItemType.sshKey.displayName == "SSH Key")
    }

    @Test("sfSymbol returns valid SF Symbol names")
    func sfSymbols() {
        #expect(ItemType.login.sfSymbol == "person.crop.circle.fill")
        #expect(ItemType.creditCard.sfSymbol == "creditcard.fill")
        #expect(ItemType.note.sfSymbol == "note.text")
    }
}

@Suite("CLI Response Parsing Tests")
struct CLIResponseParsingTests {
    @Test("parse vault list response")
    func parseVaultList() throws {
        let json = """
        {
          "vaults": [
            {"name": "Personal", "vault_id": "abc123", "share_id": "def456"},
            {"name": "Work", "vault_id": "ghi789", "share_id": "jkl012"}
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIVaultListResponse.self, from: json)
        #expect(response.vaults.count == 2)
        #expect(response.vaults[0].name == "Personal")
        #expect(response.vaults[0].vaultId == "abc123")
        #expect(response.vaults[0].shareId == "def456")
    }

    @Test("parse item list with login")
    func parseLoginItem() throws {
        let json = """
        {
          "items": [{
            "id": "item1",
            "share_id": "share1",
            "vault_id": "vault1",
            "content": {
              "title": "GitHub",
              "note": "",
              "item_uuid": "uuid1",
              "content": {
                "Login": {
                  "email": "user@example.com",
                  "username": "ghuser",
                  "password": "secret123",
                  "urls": ["https://github.com"],
                  "totp_uri": "",
                  "passkeys": []
                }
              },
              "extra_fields": []
            },
            "state": "Active",
            "flags": [],
            "create_time": "2025-08-22T17:53:41",
            "modify_time": "2025-08-22T17:53:41"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIItemListResponse.self, from: json)
        #expect(response.items.count == 1)
        let item = response.items[0]
        #expect(item.id == "item1")
        #expect(item.content.title == "GitHub")
        guard case .login(let login) = item.content.content else {
            Issue.record("Expected login type")
            return
        }
        #expect(login.username == "ghuser")
        #expect(login.email == "user@example.com")
        #expect(login.urls == ["https://github.com"])
    }

    @Test("parse item list with credit card")
    func parseCreditCardItem() throws {
        let json = """
        {
          "items": [{
            "id": "item2",
            "share_id": "share1",
            "vault_id": "vault1",
            "content": {
              "title": "Visa",
              "note": "",
              "item_uuid": "uuid2",
              "content": {
                "CreditCard": {
                  "cardholder_name": "John Doe",
                  "card_type": "Visa",
                  "number": "4111111111111111",
                  "verification_number": "123",
                  "expiration_date": "2027-12",
                  "pin": "1234"
                }
              },
              "extra_fields": []
            },
            "state": "Active",
            "flags": [],
            "create_time": "2025-08-22T17:53:41",
            "modify_time": "2025-08-22T17:53:41"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIItemListResponse.self, from: json)
        let item = response.items[0]
        guard case .creditCard(let card) = item.content.content else {
            Issue.record("Expected credit card type")
            return
        }
        #expect(card.cardholderName == "John Doe")
    }

    @Test("parse item list with note")
    func parseNoteItem() throws {
        let json = """
        {
          "items": [{
            "id": "item3",
            "share_id": "share1",
            "vault_id": "vault1",
            "content": {
              "title": "My Secret Note",
              "note": "This is sensitive",
              "item_uuid": "uuid3",
              "content": {"Note": null},
              "extra_fields": []
            },
            "state": "Active",
            "flags": [],
            "create_time": "2025-08-22T17:53:41",
            "modify_time": "2025-08-22T17:53:41"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIItemListResponse.self, from: json)
        guard case .note = response.items[0].content.content else {
            Issue.record("Expected note type")
            return
        }
    }

    @Test("parse item list with alias")
    func parseAliasItem() throws {
        let json = """
        {
          "items": [{
            "id": "item4",
            "share_id": "share1",
            "vault_id": "vault1",
            "content": {
              "title": "Shopping Alias",
              "note": "",
              "item_uuid": "uuid4",
              "content": {"Alias": null},
              "extra_fields": []
            },
            "state": "Active",
            "flags": ["AliasDisabled"],
            "create_time": "2025-08-22T17:53:41",
            "modify_time": "2025-08-22T17:53:41"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIItemListResponse.self, from: json)
        guard case .alias = response.items[0].content.content else {
            Issue.record("Expected alias type")
            return
        }
    }

    @Test("parse identity item")
    func parseIdentityItem() throws {
        let json = """
        {
          "items": [{
            "id": "item5",
            "share_id": "share1",
            "vault_id": "vault1",
            "content": {
              "title": "Personal ID",
              "note": "",
              "item_uuid": "uuid5",
              "content": {
                "Identity": {
                  "full_name": "John Doe",
                  "email": "john@example.com",
                  "phone_number": "+1234567890",
                  "first_name": "John",
                  "middle_name": "",
                  "last_name": "Doe",
                  "birthdate": "",
                  "gender": "",
                  "extra_personal_details": [],
                  "organization": "Acme",
                  "street_address": "123 Main St",
                  "zip_or_postal_code": "12345",
                  "city": "Springfield",
                  "state_or_province": "IL",
                  "country_or_region": "US",
                  "floor": "",
                  "county": "",
                  "extra_address_details": [],
                  "social_security_number": "",
                  "passport_number": "",
                  "license_number": "",
                  "website": "",
                  "x_handle": "",
                  "second_phone_number": "",
                  "linkedin": "",
                  "reddit": "",
                  "facebook": "",
                  "yahoo": "",
                  "instagram": "",
                  "extra_contact_details": [],
                  "company": "Acme Inc",
                  "job_title": "Engineer",
                  "personal_website": "",
                  "work_phone_number": "",
                  "work_email": "john@acme.com",
                  "extra_work_details": [],
                  "extra_sections": []
                }
              },
              "extra_fields": []
            },
            "state": "Active",
            "flags": [],
            "create_time": "2025-08-22T17:53:41",
            "modify_time": "2025-08-22T17:53:41"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIItemListResponse.self, from: json)
        guard case .identity(let id) = response.items[0].content.content else {
            Issue.record("Expected identity type")
            return
        }
        #expect(id.fullName == "John Doe")
        #expect(id.email == "john@example.com")
    }

    @Test("parse SSH key item")
    func parseSshKeyItem() throws {
        let json = """
        {
          "items": [{
            "id": "item6",
            "share_id": "share1",
            "vault_id": "vault1",
            "content": {
              "title": "Deploy Key",
              "note": "",
              "item_uuid": "uuid6",
              "content": {
                "SshKey": {
                  "private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\\nfake\\n-----END OPENSSH PRIVATE KEY-----",
                  "public_key": "ssh-ed25519 AAAAC3... user@host",
                  "sections": []
                }
              },
              "extra_fields": []
            },
            "state": "Active",
            "flags": [],
            "create_time": "2025-08-22T17:53:41",
            "modify_time": "2025-08-22T17:53:41"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIItemListResponse.self, from: json)
        guard case .sshKey(let key) = response.items[0].content.content else {
            Issue.record("Expected SSH key type")
            return
        }
        #expect(key.publicKey.hasPrefix("ssh-ed25519"))
    }

    @Test("parse wifi item")
    func parseWifiItem() throws {
        let json = """
        {
          "items": [{
            "id": "item7",
            "share_id": "share1",
            "vault_id": "vault1",
            "content": {
              "title": "Home WiFi",
              "note": "",
              "item_uuid": "uuid7",
              "content": {
                "Wifi": {
                  "ssid": "MyNetwork",
                  "password": "wifipass123",
                  "security": "WPA2",
                  "sections": []
                }
              },
              "extra_fields": []
            },
            "state": "Active",
            "flags": [],
            "create_time": "2025-08-22T17:53:41",
            "modify_time": "2025-08-22T17:53:41"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIItemListResponse.self, from: json)
        guard case .wifi(let wifi) = response.items[0].content.content else {
            Issue.record("Expected wifi type")
            return
        }
        #expect(wifi.ssid == "MyNetwork")
    }

    @Test("parse TOTP response")
    func parseTotpResponse() throws {
        let json = """
        {"totp_uri": "463663", "totp": "463663"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLITotpResponse.self, from: json)
        #expect(response.totp == "463663")
    }

    @Test("trashed items have correct state")
    func trashedState() throws {
        let json = """
        {
          "items": [{
            "id": "item8",
            "share_id": "share1",
            "vault_id": "vault1",
            "content": {
              "title": "Old Item",
              "note": "",
              "item_uuid": "uuid8",
              "content": {"Note": null},
              "extra_fields": []
            },
            "state": "Trashed",
            "flags": [],
            "create_time": "2025-08-22T17:53:41",
            "modify_time": "2025-08-22T17:53:41"
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CLIItemListResponse.self, from: json)
        #expect(response.items[0].state == "Trashed")
    }
}
