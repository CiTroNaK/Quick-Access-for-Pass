import AppKit
import Foundation
import SwiftUI
import os

nonisolated enum AutoFillLaunchURL {
    /// Accepts only the non-secret wake shape emitted by the extension.
    /// The returned UUID is a launch handle, never a descriptor or authorization.
    static func parse(_ url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "quickaccesspass",
              components.host == "autofill",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedPath.isEmpty,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "nonce",
              let value = queryItems[0].value,
              value.isEmpty == false,
              components.percentEncodedQuery == "nonce=\(value)",
              let handle = UUID(uuidString: value) else {
            return nil
        }
        return handle
    }
}

nonisolated enum AutoFillWakeRegistrationDisposition: Sendable {
    case bufferedForStartup
    case registerImmediately
}

/// Synchronously records bounded, non-secret launch metadata before actor work
/// can register it with the request registry.
nonisolated final class AutoFillLaunchGate: Sendable {
    private static let maximumInitialRegistrations = 64

    private enum Phase: Sendable {
        case collecting
        case starting
        case ready
    }

    private struct State: Sendable {
        var phase: Phase = .collecting
        var startupRegistrations: [(handle: UUID, deadline: UInt64)] = []
        var initialClaims: [(handle: UUID, deadline: UInt64)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func recordWake(
        handle: UUID,
        deadline: UInt64
    ) -> AutoFillWakeRegistrationDisposition {
        state.withLock { state in
            switch state.phase {
            case .collecting:
                let registration = (handle, deadline)
                if state.initialClaims.count < Self.maximumInitialRegistrations {
                    state.startupRegistrations.append(registration)
                    state.initialClaims.append(registration)
                }
                return .bufferedForStartup
            case .starting:
                if state.initialClaims.count < Self.maximumInitialRegistrations {
                    state.initialClaims.append((handle, deadline))
                }
                return .registerImmediately
            case .ready:
                return .registerImmediately
            }
        }
    }

    func drainStartupRegistrations() -> [(handle: UUID, deadline: UInt64)] {
        state.withLock { state in
            let registrations = state.startupRegistrations
            state.startupRegistrations.removeAll(keepingCapacity: true)
            return registrations
        }
    }

    /// Transitions to startup only after all collection-time registrations were
    /// drained, so no URL can be stranded between the drain and listener start.
    func beginBrokerStart() -> Bool {
        state.withLock { state in
            guard state.phase == .collecting else { return true }
            guard state.startupRegistrations.isEmpty else { return false }
            state.phase = .starting
            return true
        }
    }

    func requiresInitialClaim(at now: UInt64) -> Bool {
        state.withLock { state in
            state.initialClaims.removeAll { $0.deadline <= now }
            return state.initialClaims.isEmpty == false
        }
    }

    func completeInitialClaim(handle: UUID, deadline: UInt64) {
        state.withLock { state in
            guard state.initialClaims.contains(where: {
                $0.handle == handle && deadline <= $0.deadline
            }) else {
                return
            }
            // Any verified initial claim completes bootstrap admission. The
            // registry retains the remaining handles' independent replay state.
            state.initialClaims.removeAll(keepingCapacity: false)
        }
    }

    func markListenerReady() {
        state.withLock { $0.phase = .ready }
    }
}

@MainActor
struct LiveAutoFillAccessibilityAdapter: AutoFillAccessibilityPresenting {
    let recoverFocus: @MainActor @Sendable () -> Void

    func announce(_ event: AutoFillAccessibilityEvent) {
        AccessibilityNotification.Announcement(event.announcement).post()
    }

    func recoverFocusAfterAuthenticationFailure() {
        recoverFocus()
    }
}

extension AppDelegate {
    /// Handles only an unauthorizing wake hint. AppKit has already launched the
    /// accessory app; this callback deliberately does not activate it or show UI.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            _ = handleAutoFillLaunchURL(url)
        }
    }

    @discardableResult
    func handleAutoFillLaunchURL(_ url: URL) -> Bool {
        guard let handle = AutoFillLaunchURL.parse(url) else { return false }

        let current = autoFillLaunchNow()
        let (sum, overflow) = current.addingReportingOverflow(30_000_000_000)
        let deadline = overflow ? UInt64.max : sum
        switch autoFillLaunchGate.recordWake(handle: handle, deadline: deadline) {
        case .bufferedForStartup:
            break // setupAutoFillBroker drains this registration exactly once.
        case .registerImmediately:
            let registry = autoFillRequestRegistry
            Task {
                // Duplicate/capacity/expiry failures are intentionally silent and
                // never include the URL or its query value in logs.
                try? await registry.registerWake(handle: handle, deadline: deadline)
            }
        }
        return true
    }

    func requestUnlockAccessibilityFocus() {
        unlockAccessibilityFocusRequestID = UUID()
    }
}
