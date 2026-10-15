import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline source modification time")
struct OfflineSourceModificationTimeTests {
    @Test("valid source forms preserve the same UTC instant", arguments: [
        "2026-10-01T12:00:00Z", "2026-10-01T12:00:00", "2026-10-01T12:00:00.000Z",
        "2026-10-01T12:00:00.000", "2026-10-01T14:00:00+02:00"
    ])
    func equivalentInstants(raw: String) throws {
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))
        #expect(OfflineSourceModificationTime.parse(raw) == expected)
    }

    @Test("invalid source markers never manufacture current time", arguments: [
        "", "unknown", "2026-13-01T12:00:00", "2026-10-01", "2026-10-01T12:00:00garbage"
    ])
    func invalidTimes(raw: String) {
        #expect(OfflineSourceModificationTime.parse(raw) == nil)
    }

    @Test("regressed source time remains a distinct version")
    func regressionIsNotFreshness() throws {
        let older = try #require(OfflineSourceModificationTime.parse("2026-09-30T12:00:00Z"))
        let newer = try #require(OfflineSourceModificationTime.parse("2026-10-01T12:00:00Z"))
        #expect(older < newer)
        #expect(older != newer)
    }

    @Test("ordinary metadata understands the CLI's UTC civil timestamps")
    func civilSourceTimeDoesNotFallBackToNow() throws {
        let item = try JSONDecoder().decode(CLIItem.self, from: Data("""
            {"id":"item","share_id":"share","vault_id":"vault","modify_time":"2026-10-01T12:00:00",
             "content":{"content":{"Note":null}}}
            """.utf8))
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))
        #expect(PassItem(from: item, vaultId: "vault").modifyTime == expected)
    }
}
