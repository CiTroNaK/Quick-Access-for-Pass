// Quick Access for Pass Tests/Helpers/FakeHealthCheckers.swift
import Foundation
@testable import Quick_Access_for_Pass

/// Test fakes. Marked `@MainActor` explicitly because the test target does
/// NOT enable `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (only the main app
/// target and qa-run helper do). `@MainActor` isolation makes the mutable
/// state Sendable-safe without needing `@unchecked Sendable`. Coordinator
/// tests that use these fakes are also `@MainActor`, so the protocol's
/// `async` requirement is satisfied intra-actor.
@MainActor
final class FakePassCLIHealthChecker: PassCLIHealthChecking {
    var nextOutcome = PassCLIProbeOutcome(health: .ok, identity: nil, version: nil)
    var callCount = 0
    var onCheck: (@Sendable () -> Void)?

    func check(cliPath: String) async -> PassCLIProbeOutcome {
        callCount += 1
        onCheck?()
        return nextOutcome
    }
}

@MainActor
final class FakeRunProbeChecker: RunProbeChecking {
    var nextResult: RunProbeResult = .healthy
    var callCount = 0
    var onCheck: (@Sendable () -> Void)?

    func check(socketPath: String) async -> RunProbeResult {
        callCount += 1
        onCheck?()
        return nextResult
    }
}

@MainActor
final class FakeSSHProbeChecker: SSHProbeChecking {
    var nextResult: SSHProbeResult = .healthy(identityCount: 2)
    var callCount = 0
    var onCheck: (@Sendable () -> Void)?

    func check(listenPath: String) async -> SSHProbeResult {
        callCount += 1
        onCheck?()
        return nextResult
    }
}
