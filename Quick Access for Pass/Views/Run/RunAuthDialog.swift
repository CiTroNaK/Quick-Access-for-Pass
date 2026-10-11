import SwiftUI
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import AppKit

nonisolated struct RunAuthRequest: Sendable {
    let appName: String
    let appBundleURL: URL?
    var headerModel: RequesterHeaderModel? = nil
    let profileName: String
    let command: String
    let scopeOptions: [RunAuthorizationScope]
    let keychainService: any BiometricAuthorizing
    let callbacks: AuthDialogHelper.Callbacks
    let onResult: @MainActor @Sendable (Bool, RememberDuration, RunAuthorizationIdentity?) -> Void
}

struct RunAuthDialogView: View {
    let request: RunAuthRequest
    @State private var rememberDuration: RememberDuration = .doNotRemember
    @State private var selectedScope: RunAuthorizationIdentity?
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
        _selectedScope = State(initialValue: request.scopeOptions.first?.identity)
    }

    private enum AuthState {
        case idle
        case authenticating
        case failed(AuthDialogHelper.FailurePresentation)
    }

    var body: some View {
        VStack(spacing: 16) {
            RequesterHeaderView(model: request.headerModel, fallbackName: request.appName,
                                fallbackBundleURL: request.appBundleURL, subtitle: "wants to use secrets from \(request.profileName)")

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
                    RunAuthScopeText(text: request.scopeOptions[0].optionLabel)
                        .accessibilityLabel(request.scopeOptions[0].optionLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack {
                        Text("Applies to")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Picker("", selection: $selectedScope) {
                            ForEach(request.scopeOptions, id: \.identity) { scope in
                                Text(scope.optionLabel)
                                    .font(.system(.caption, design: .monospaced))
                                    .tag(Optional(scope.identity))
                                    .accessibilityLabel(scope.optionLabel)
                            }
                        }
                        .frame(width: 180)
                        .accessibilityLabel(String(localized: "Scope"))
                    }
                }
                if !request.scopeOptions.isEmpty {
                    RunAuthScopeText(text: String(localized: "Exact matches every argument. Broader scopes also match commands with different arguments."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        request.onResult(allowed, rememberDuration, selectedScope)
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

// Prompt labels are transient; typed scope identities alone drive selection and authorization.
extension RunAuthorizationScope {
    nonisolated var optionLabel: String {
        if isExact {
            return String(
                localized: "Exact command: \(label)",
                comment: "Exact argv scope option. Placeholder is the natural full command text; do not translate the command."
            )
        }
        return String(localized: "Broader scope: \(label)",
                      comment: "Explicit command-prefix permission. Placeholder is the unchanged command prefix, not the exact argument vector.")
    }
}
