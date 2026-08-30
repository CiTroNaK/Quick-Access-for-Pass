import Testing
@testable import Quick_Access_for_Pass

@Suite("Search focus retry")
@MainActor
struct SearchFocusRetrierTests {
    @Test("Stops after focus succeeds")
    func stopsAfterFocusSucceeds() async {
        var attempts = 0
        var waits = 0

        await SearchFocusRetrier.run(
            whileEligible: { true },
            attempt: {
                attempts += 1
                return attempts == 3
            },
            waitForRetry: {
                waits += 1
                return true
            }
        )

        #expect(attempts == 3)
        #expect(waits == 2)
    }

    @Test("Reclaims the panel before requesting focus")
    func reclaimsPanelBeforeRequestingFocus() async {
        var isPanelKey = false
        var isFocused = false
        var reclaims = 0
        var requests = 0
        var waits = 0

        await SearchFocusRetrier.focus(
            whileEligible: { true },
            isPanelKey: { isPanelKey },
            reclaimPanel: {
                reclaims += 1
                isPanelKey = true
            },
            isFocused: { isFocused },
            requestFocus: {
                requests += 1
                isFocused = true
            },
            waitForRetry: {
                waits += 1
                return true
            }
        )

        #expect(reclaims == 1)
        #expect(requests == 1)
        #expect(waits == 1)
    }

    @Test("Stops when waiting is canceled")
    func stopsWhenWaitingIsCanceled() async {
        var attempts = 0
        var waits = 0

        await SearchFocusRetrier.run(
            whileEligible: { true },
            attempt: {
                attempts += 1
                return false
            },
            waitForRetry: {
                waits += 1
                return false
            }
        )

        #expect(attempts == 1)
        #expect(waits == 1)
    }
}
