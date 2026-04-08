import Testing
import Foundation
@testable import Quick_Access_for_Pass

@MainActor
struct ProxyCoordinatorGuardTests {

    @Test func beginGenerationReturnsMonotonicValues() {
        var state = ProxyGuardState()
        let g1 = state.beginGeneration()
        let g2 = state.beginGeneration()
        let g3 = state.beginGeneration()
        #expect(g1 == 1)
        #expect(g2 == 2)
        #expect(g3 == 3)
        #expect(state.proxyGeneration == 3)
    }

    @Test func isCurrentRejectsStaleGenerations() {
        var state = ProxyGuardState()
        let g1 = state.beginGeneration()
        _ = state.beginGeneration()
        #expect(state.isCurrent(g1) == false,
                "generation 1 should be stale after bump to 2")
        #expect(state.isCurrent(state.proxyGeneration) == true)
    }

    @Test func isCurrentAcceptsFreshGeneration() {
        var state = ProxyGuardState()
        let gen = state.beginGeneration()
        #expect(state.isCurrent(gen) == true)
    }

    @Test func beginRestartSucceedsWhenNotInFlight() {
        var state = ProxyGuardState()
        #expect(state.beginRestart() == true)
        #expect(state.isRestartInFlight == true)
    }

    @Test func beginRestartRejectsReentry() {
        var state = ProxyGuardState()
        _ = state.beginRestart()
        #expect(state.beginRestart() == false,
                "second beginRestart should return false while in flight")
        #expect(state.isRestartInFlight == true)
    }

    @Test func endRestartClearsTheFlag() {
        var state = ProxyGuardState()
        _ = state.beginRestart()
        state.endRestart()
        #expect(state.isRestartInFlight == false)
        #expect(state.beginRestart() == true,
                "a subsequent restart should be allowed")
    }

    @Test func generationSurvivesRestartCycle() {
        var state = ProxyGuardState()
        let genBefore = state.beginGeneration()
        _ = state.beginRestart()
        state.endRestart()
        #expect(state.proxyGeneration == genBefore)
    }
}
