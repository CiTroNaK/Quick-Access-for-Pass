import SwiftUI
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import AppKit

nonisolated struct SSHAuthRequest: Sendable {
    let appName: String
    let appBundleURL: URL?
    let keyName: String
    /// The user-facing command that triggered the SSH connection (e.g., "git fetch --all"
    /// or "ssh git@github.com" for direct SSH). Shown in the dialog and copied by the copy button.
    let triggerCommand: String?
    /// Whether to display the command in the dialog (true for terminals, false for GUI apps).
    let showCommand: Bool
    /// The target host parsed from the SSH command (e.g., "github.com"), if available.
    let host: String?
    let keychainService: any BiometricAuthorizing
    let callbacks: AuthDialogHelper.Callbacks
    let onResult: @Sendable (Bool, RememberDuration) -> Void
}

struct EmbeddedTouchIDView: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: self.context, controlSize: .small)
    }

    func updateNSView(_ nsView: LAAuthenticationView, context: Context) {}
}

struct SSHAuthDialogView: View {
    let request: SSHAuthRequest
    @State private var rememberDuration: RememberDuration = .doNotRemember
    @State private var authState: AuthState = .idle
    @State private var timeRemaining: Int = 30
    @State private var resultSent = false
    @State private var authContext: LAContext = {
        let ctx = LAContext()
        ctx.localizedCancelTitle = String(localized: "Cancel")
        ctx.localizedFallbackTitle = ""
        return ctx
    }()
    @State private var retryCount = 0
    @AccessibilityFocusState private var isTryAgainFocused: Bool

    private enum AuthState {
        case idle
        case authenticating
        case failed(AuthDialogHelper.FailurePresentation)
    }

    private var appIcon: NSImage {
        if let url = request.appBundleURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.applicationIconName)!
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.appName)
                        .font(.headline)
                    Text("wants to use an SSH key")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if request.showCommand, let triggerCommand = request.triggerCommand {
                HStack {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(triggerCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(triggerCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Copy command"))
                }
                .padding(.horizontal, 4)
            }

            Divider()

            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(request.keyName)
                    .font(.system(.body, design: .monospaced))
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Remember for")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $rememberDuration) {
                        ForEach(RememberDuration.allCases) { duration in
                            Text(duration.localizedLabel).tag(duration)
                        }
                    }
                    .frame(width: 180)
                }
                if let host = request.host {
                    if let triggerCommand = request.triggerCommand,
                       !triggerCommand.hasPrefix("ssh ") {
                        Text("Applies to \(triggerCommand) on \(host)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Applies to all SSH connections to \(host)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Divider()

            HStack {
                Button("Deny") {
                    sendResult(allowed: false)
                }
                .keyboardShortcut(.cancelAction)
                Text("\(timeRemaining)s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                switch authState {
                case .authenticating:
                    Text("Authorize with")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .failed(let presentation):
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(presentation.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                        if presentation.showsRetryButton {
                            Button("Try Again") {
                                let ctx = LAContext()
                                ctx.localizedCancelTitle = String(localized: "Cancel")
                                ctx.localizedFallbackTitle = ""
                                authContext = ctx
                                retryCount += 1
                                Task { await authenticate() }
                            }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityFocused($isTryAgainFocused)
                        }
                    }
                case .idle:
                    EmptyView()
                }
                EmbeddedTouchIDView(context: authContext)
                    .frame(width: 20, height: 20)
                    .id(retryCount)
                    .padding(.leading, 4)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task {
            while !Task.isCancelled && timeRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                timeRemaining -= 1
            }
            if timeRemaining <= 0 {
                sendResult(allowed: false)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await authenticate()
        }
    }

    private func sendResult(allowed: Bool) {
        guard !resultSent else { return }
        resultSent = true
        request.onResult(allowed, rememberDuration)
    }

    private func authenticate() async {
        var preflightError: NSError?
        guard authContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &preflightError) else {
            let presentation = AuthDialogHelper.preflightFailurePresentation(for: preflightError)
            authState = .failed(presentation)
            isTryAgainFocused = presentation.showsRetryButton
            return
        }

        authState = .authenticating

        let outcome = await AuthDialogHelper.runAuthorize(
            context: authContext,
            authorizer: request.keychainService,
            kind: .ssh,
            localizedReason: String(localized: "authorize \(request.appName) to use SSH key \"\(request.keyName)\""),
            callbacks: request.callbacks
        )

        switch outcome {
        case .allowed:
            sendResult(allowed: true)
        case .denied(let error):
            let presentation = AuthDialogHelper.failurePresentation(for: error)
            authState = .failed(presentation)
            isTryAgainFocused = presentation.showsRetryButton
        }
    }
}
