import SwiftUI
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import AppKit

nonisolated struct RunAuthRequest: Sendable {
    let appName: String
    let appBundleURL: URL?
    let profileName: String
    let command: String
    let scopeOptions: [String]
    let keychainService: any BiometricAuthorizing
    let callbacks: AuthDialogHelper.Callbacks
    let onResult: @Sendable (Bool, RememberDuration, String?) -> Void
}

struct RunAuthDialogView: View {
    let request: RunAuthRequest
    @State private var rememberDuration: RememberDuration = .doNotRemember
    @State private var selectedScope: String
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

    init(request: RunAuthRequest) {
        self.request = request
        _selectedScope = State(initialValue: request.scopeOptions.first ?? "")
    }

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
                    Text("wants to use secrets from \(request.profileName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(request.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(request.command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Copy command"))
            }
            .padding(.horizontal, 4)

            Divider()

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
                    .disabled(request.scopeOptions.isEmpty)
                    .accessibilityLabel(String(localized: "Remember for"))
                }

                if request.scopeOptions.isEmpty {
                    Text("This command can't be safely remembered.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if request.scopeOptions.count == 1 {
                    Text("Applies to \(request.scopeOptions[0])")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack {
                        Text("Applies to")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Picker("", selection: $selectedScope) {
                            ForEach(request.scopeOptions, id: \.self) { scope in
                                Text(scope)
                                    .font(.system(.caption, design: .monospaced))
                                    .tag(scope)
                            }
                        }
                        .frame(width: 180)
                        .accessibilityLabel(String(localized: "Scope"))
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
        let scope: String? = allowed && !selectedScope.isEmpty ? selectedScope : nil
        request.onResult(allowed, rememberDuration, scope)
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
            kind: .run,
            localizedReason: String(localized: "authorize \(request.appName) to run with \(request.profileName) secrets"),
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
