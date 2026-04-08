import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("FormatHelpers Tests")
struct FormatHelpersTests {
    @Test func relativeExpirationReturnsForeverForNil() {
        let result = FormatHelpers.relativeExpiration(nil)
        #expect(result == String(localized: "Forever"))
    }

    @Test func relativeExpirationReturnsHoursForFutureDate() {
        let future = Date().addingTimeInterval(3 * 3600 + 30 * 60 + 30)
        let result = FormatHelpers.relativeExpiration(future)
        #expect(result.contains("3h"))
        #expect(result.contains("30m"))
    }

    @Test func relativeExpirationReturnsSecondsForSoon() {
        let soon = Date().addingTimeInterval(45)
        let result = FormatHelpers.relativeExpiration(soon)
        #expect(result.hasPrefix(String(localized: "expires in")))
        #expect(result.hasSuffix("s"))
        #expect(!result.contains("m"))
        #expect(!result.contains("h"))
    }

    @Test func relativeExpirationReturnsMinutesForMidRange() {
        let future = Date().addingTimeInterval(45 * 60 + 30)
        let result = FormatHelpers.relativeExpiration(future)
        #expect(result.contains("45m"))
        #expect(!result.contains("h"))
    }

    @Test func relativeExpirationReturnsDaysForFarFuture() {
        let future = Date().addingTimeInterval(4 * 86400 + 3600)
        let result = FormatHelpers.relativeExpiration(future)
        #expect(result.contains("4d"))
    }
}
