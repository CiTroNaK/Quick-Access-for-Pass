import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("FieldKey")
struct FieldKeyTests {

    private func roundtrip(_ key: FieldKey) throws -> FieldKey {
        let data = try JSONEncoder().encode(key)
        return try JSONDecoder().decode(FieldKey.self, from: data)
    }

    @Test("roundtrips a built-in case")
    func roundtripsBuiltin() throws {
        let decoded = try roundtrip(.cardCVV)
        #expect(decoded == .cardCVV)
    }

    @Test("roundtrips an extra case with a name")
    func roundtripsExtra() throws {
        let decoded = try roundtrip(.extra(
            path: .topLevel(fieldIndex: 0),
            name: "Recovery Code",
            isSensitive: true
        ))
        #expect(decoded == .extra(
            path: .topLevel(fieldIndex: 0),
            name: "Recovery Code",
            isSensitive: true
        ))
    }

    @Test("roundtrips a section header case with a name")
    func roundtripsSectionHeader() throws {
        let decoded = try roundtrip(.sectionHeader(name: "Bank"))
        #expect(decoded == .sectionHeader(name: "Bank"))
    }

    @Test("roundtrips a list preserving order")
    func roundtripsOrderedList() throws {
        let original: [FieldKey] = [
            .cardholderName, .cardExpiration, .cardCVV,
            .extra(path: .topLevel(fieldIndex: 0), name: "Memo", isSensitive: false),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([FieldKey].self, from: data)
        #expect(decoded == original)
    }

    @Test("isSensitive flags secret built-ins")
    func sensitiveFlags() {
        // Sensitive built-ins
        #expect(FieldKey.cardCVV.isSensitive)
        #expect(FieldKey.cardPIN.isSensitive)
        #expect(FieldKey.sshPrivateKey.isSensitive)
        #expect(FieldKey.identitySocialSecurityNumber.isSensitive)
        #expect(FieldKey.identityPassportNumber.isSensitive)
        #expect(FieldKey.identityLicenseNumber.isSensitive)
        // Non-sensitive built-ins — one per item-type family so a future
        // misclassification stays visible instead of falling through a
        // `default:` arm.
        #expect(FieldKey.email.isSensitive == false)
        #expect(FieldKey.cardholderName.isSensitive == false)
        #expect(FieldKey.cardType.isSensitive == false)
        #expect(FieldKey.cardExpiration.isSensitive == false)
        #expect(FieldKey.wifiSSID.isSensitive == false)
        #expect(FieldKey.wifiSecurity.isSensitive == false)
        #expect(FieldKey.noteBody.isSensitive == false)
        #expect(FieldKey.identityFullName.isSensitive == false)
        #expect(FieldKey.identityPhoneNumber.isSensitive == false)
        #expect(FieldKey.identityWebsite.isSensitive == false)
        #expect(FieldKey.identityWorkEmail.isSensitive == false)
        // Extra: isSensitive mirrors the payload flag.
        #expect(FieldKey.extra(path: .topLevel(fieldIndex: 0), name: "x", isSensitive: false).isSensitive == false)
        #expect(FieldKey.extra(path: .topLevel(fieldIndex: 0), name: "secret", isSensitive: true).isSensitive == true)
        // Section header is non-selectable but still part of the enum.
        #expect(FieldKey.sectionHeader(name: "Bank").isSensitive == false)
    }

    @Test("localizedLabel returns verbatim name for extra and sectionHeader")
    func verbatimExtraLabel() {
        #expect(
            FieldKey.extra(
                path: .topLevel(fieldIndex: 0),
                name: "Recovery Code",
                isSensitive: true
            ).localizedLabel == "Recovery Code"
        )
        #expect(FieldKey.sectionHeader(name: "Bank").localizedLabel == "Bank")
    }

    @Test("roundtrips an extra case with exact top-level path")
    func roundtripsExtraTopLevelPath() throws {
        let decoded = try roundtrip(.extra(
            path: .topLevel(fieldIndex: 2),
            name: "Recovery Code",
            isSensitive: true
        ))
        #expect(decoded == .extra(
            path: .topLevel(fieldIndex: 2),
            name: "Recovery Code",
            isSensitive: true
        ))
    }

    @Test("roundtrips an extra case with exact custom-section path")
    func roundtripsExtraSectionPath() throws {
        let decoded = try roundtrip(.extra(
            path: .customSection(sectionIndex: 1, fieldIndex: 0),
            name: "Account",
            isSensitive: false
        ))
        #expect(decoded == .extra(
            path: .customSection(sectionIndex: 1, fieldIndex: 0),
            name: "Account",
            isSensitive: false
        ))
    }

    @Test("stableIdentifier distinguishes duplicate visible names by path")
    func stableIdentifierIncludesPath() {
        let top = FieldKey.extra(path: .topLevel(fieldIndex: 0), name: "Code", isSensitive: false)
        let section = FieldKey.extra(
            path: .customSection(sectionIndex: 0, fieldIndex: 0),
            name: "Code",
            isSensitive: false
        )
        #expect(top.stableIdentifier != section.stableIdentifier)
    }

    @Test("encoded built-in tags remain stable")
    func encodedTagStaysStable() throws {
        let data = try JSONEncoder().encode(FieldKey.cardCVV)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"tag\":\"cardCVV\""))
    }

    @Test("stableIdentifier for custom path remains unchanged")
    func extraStableIdentifierStaysStable() {
        let key = FieldKey.extra(
            path: .customSection(sectionIndex: 1, fieldIndex: 2),
            name: "Account",
            isSensitive: false
        )
        #expect(key.stableIdentifier == "extra:customSection:1:2:Account")
    }
}
