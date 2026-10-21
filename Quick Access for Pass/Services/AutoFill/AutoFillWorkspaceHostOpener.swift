import AppKit
import Foundation
import os

@MainActor
struct WorkspaceAutoFillHostOpener: AutoFillHostOpening {
    func open(handle: UUID) async throws -> Bool {
        var components = URLComponents()
        components.scheme = "quickaccesspass"
        components.host = "autofill"
        components.queryItems = [URLQueryItem(name: "nonce", value: handle.uuidString)]
        guard let url = components.url else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let gate = AutoFillWorkspaceOpenGate()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard gate.install(continuation) else { return }
                NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                    gate.finish(.opened(error == nil))
                }
            }
        } onCancel: {
            gate.finish(.cancelled)
        }

        switch outcome {
        case .opened(let succeeded): return succeeded
        case .cancelled: throw CancellationError()
        }
    }
}

nonisolated private enum AutoFillWorkspaceOpenOutcome: Sendable {
    case opened(Bool)
    case cancelled
}

/// Makes the callback API cancellation-aware so a deadline task group can
/// cancel and fully drain the opener even if AppKit never invokes its callback.
nonisolated private final class AutoFillWorkspaceOpenGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<AutoFillWorkspaceOpenOutcome, Never>?
        var outcome: AutoFillWorkspaceOpenOutcome?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(
        _ continuation: CheckedContinuation<AutoFillWorkspaceOpenOutcome, Never>
    ) -> Bool {
        let outcome = state.withLock { state -> AutoFillWorkspaceOpenOutcome? in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        guard let outcome else { return true }
        continuation.resume(returning: outcome)
        return false
    }

    func finish(_ outcome: AutoFillWorkspaceOpenOutcome) {
        let continuation = state.withLock { state -> CheckedContinuation<AutoFillWorkspaceOpenOutcome, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }
}
