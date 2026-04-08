import Testing
@testable import Quick_Access_for_Pass

@Suite
struct LockoutTimeoutTests {
    @Test
    func allCasesReturnPositiveIntervals() {
        for timeout in LockoutTimeout.allCases {
            #expect(timeout.seconds > 0)
        }
    }

    @Test
    func fifteenMinutesReturns900() {
        #expect(LockoutTimeout.fifteenMinutes.seconds == 900)
    }

    @Test
    func oneWeekReturns3600() {
        #expect(LockoutTimeout.oneHour.seconds == 3_600)
    }

    @Test
    func twelveHoursReturns43200() {
        #expect(LockoutTimeout.twelveHours.seconds == 43_200)
    }

    @Test
    func localizedLabelIsNotEmpty() {
        for timeout in LockoutTimeout.allCases {
            #expect(!timeout.localizedLabel.isEmpty)
        }
    }

    @Test
    func rawValueRoundTrips() {
        for timeout in LockoutTimeout.allCases {
            #expect(LockoutTimeout(rawValue: timeout.rawValue) == timeout)
        }
    }

    @Test
    func defaultTimeoutIsOneHour() {
        #expect(LockoutTimeout.default == .oneHour)
    }
}
