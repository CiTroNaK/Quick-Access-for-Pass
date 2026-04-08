import Foundation
import Observation
import SwiftUI

/// Observable source of truth for proxy health. Bound by Settings views via `.environment`.
///
/// The Observation macro preserves `willSet`/`didSet` observers — this is the documented
/// way to react to property changes. Worsening transitions (severity increases) post
/// VoiceOver announcements; improvements are intentionally silent to avoid noise under
/// cooldown churn.
@Observable
@MainActor
final class ProxyHealthStore {
    var sshHealth: ProxyHealthState = .disabled {
        didSet { announceIfWorsening(old: oldValue, new: sshHealth, prefix: "SSH agent") }
    }

    var runHealth: ProxyHealthState = .disabled {
        didSet { announceIfWorsening(old: oldValue, new: runHealth, prefix: "Run proxy") }
    }

    init() {}

    private func announceIfWorsening(
        old: ProxyHealthState,
        new: ProxyHealthState,
        prefix: String
    ) {
        guard old.severity < new.severity else { return }
        let message: String
        switch new {
        case .degraded:    message = "\(prefix) is degraded"
        case .unreachable: message = "\(prefix) is unreachable"
        case .ok, .disabled: return
        }
        AccessibilityNotification.Announcement(message).post()
    }
}
