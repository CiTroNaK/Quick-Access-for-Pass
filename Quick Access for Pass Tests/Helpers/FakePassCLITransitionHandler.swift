import Foundation
@testable import Quick_Access_for_Pass

@MainActor
final class FakePassCLITransitionHandler: PassCLIHealthTransitionHandling {
    var transitions: [PassCLIHealth] = []

    func handleCLIHealthTransition(to health: PassCLIHealth) {
        transitions.append(health)
    }
}
