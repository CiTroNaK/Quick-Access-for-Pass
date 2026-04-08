import Testing
import Foundation
@testable import Quick_Access_for_Pass

@Suite("RememberDuration Tests")
struct RememberDurationTests {

    @Test func doNotRememberResolvesToDoNotRemember() {
        if case .doNotRemember = RememberDuration.doNotRemember.resolved() {
            // pass
        } else {
            Issue.record("Expected .doNotRemember")
        }
    }

    @Test func foreverResolvesToForever() {
        if case .forever = RememberDuration.forever.resolved() {
            // pass
        } else {
            Issue.record("Expected .forever")
        }
    }

    @Test("timed duration resolves to expected interval", arguments: [
        (RememberDuration.oneMinute, 60.0),
        (RememberDuration.fiveMinutes, 300.0),
        (RememberDuration.fifteenMinutes, 900.0),
        (RememberDuration.thirtyMinutes, 1800.0),
        (RememberDuration.oneHour, 3600.0),
        (RememberDuration.twoHours, 7200.0),
        (RememberDuration.fourHours, 14400.0),
        (RememberDuration.oneWeek, 604800.0),
        (RememberDuration.twoWeeks, 1209600.0),
    ])
    func timedInterval(duration: RememberDuration, expectedSeconds: Double) throws {
        let now = Date()
        guard case .expires(let expiry) = duration.resolved(from: now) else {
            Issue.record("Expected .expires case for \(duration)")
            return
        }
        #expect(abs(expiry.timeIntervalSince(now) - expectedSeconds) < 1)
    }

    @Test func untilEndOfDayResolvesToMidnight() throws {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let components = DateComponents(year: 2025, month: 1, day: 15, hour: 14, minute: 30)
        let now = try #require(calendar.date(from: components))

        guard case .expires(let expiry) = RememberDuration.untilEndOfDay.resolved(from: now) else {
            Issue.record("Expected .expires for untilEndOfDay")
            return
        }

        let expectedComponents = DateComponents(year: 2025, month: 1, day: 16, hour: 0, minute: 0, second: 0)
        let expected = try #require(calendar.date(from: expectedComponents))
        #expect(abs(expiry.timeIntervalSince(expected)) < 1)
    }

    @Test func untilEndOfDayNearMidnightResolvesToNextDay() throws {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let components = DateComponents(year: 2025, month: 1, day: 15, hour: 23, minute: 59, second: 30)
        let now = try #require(calendar.date(from: components))

        guard case .expires(let expiry) = RememberDuration.untilEndOfDay.resolved(from: now) else {
            Issue.record("Expected .expires for untilEndOfDay")
            return
        }
        let nextDay = DateComponents(year: 2025, month: 1, day: 16, hour: 0, minute: 0, second: 0)
        let expected = try #require(calendar.date(from: nextDay))
        #expect(abs(expiry.timeIntervalSince(expected)) < 1)
    }

    @Test func allCasesHaveIdentifiers() {
        for duration in RememberDuration.allCases {
            #expect(duration.id.isEmpty == false)
            #expect(duration.id == duration.rawValue)
        }
    }

    @Test func newCasesExist() {
        #expect(RememberDuration.allCases.contains(.oneWeek))
        #expect(RememberDuration.allCases.contains(.twoWeeks))
        #expect(RememberDuration.allCases.contains(.forever))
    }

    @Test func pickerOrderPlacesWeeksBeforeUntilEndOfDayAndForeverLast() throws {
        let slugs = RememberDuration.allCases.map(\.rawValue)
        let weeksIdx1 = try #require(slugs.firstIndex(of: "1 week"))
        let weeksIdx2 = try #require(slugs.firstIndex(of: "2 weeks"))
        let eodIdx = try #require(slugs.firstIndex(of: "Until end of day"))
        let foreverIdx = try #require(slugs.firstIndex(of: "Forever"))
        #expect(weeksIdx1 < weeksIdx2)
        #expect(weeksIdx2 < eodIdx)
        #expect(foreverIdx == slugs.count - 1)
    }
}
